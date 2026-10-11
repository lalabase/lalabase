# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RemoveMembershipService, type: :service do
  let(:organisation) { create(:organisation) }
  let(:admin_user) { create(:user) }
  let(:target_user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end
  let(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: target_user, organisation: organisation, active: true)
    end
  end

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      admin_role = organisation.find_or_create_account_admin_role
      create(:membership, user: admin_user, organisation: organisation, role: admin_role, active: true)
    end
  end

  describe '#call' do
    subject(:service) do
      described_class.new(
        membership: membership,
        admin: admin_user
      )
    end

    context 'successful membership removal' do
      before do
        # Ensure membership exists before test
        membership
        # Ensure admin membership exists
        admin_membership
      end

      it 'removes the membership' do
        expect { service.call }.to change(Membership, :count).by(-1)
      end

      it 'returns true' do
        result = service.call
        expect(service.errors).to be_empty
        expect(result).to be true
      end

      it 'destroys the membership record' do
        service.call
        expect { membership.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'broadcasts membership removal event' do
        # Set up the expectation to allow other notifications to pass through
        allow(ActiveSupport::Notifications).to receive(:instrument).and_call_original

        expect(ActiveSupport::Notifications).to receive(:instrument)
          .with('membership.removed', hash_including(
                                        user_id: target_user.id,
                                        organisation_id: organisation.id,
                                        admin_id: admin_user.id
                                      ))
          .and_call_original

        service.call
      end

      it 'logs the membership removal' do
        expect(Rails.logger).to receive(:info)
          .with(/Membership removal event: User .* removed from organisation .* by admin .*/)

        service.call
      end
    end

    context 'real integration: removing the last membership actually flags the user' do
      # The "should be recommended" context below stubs the predicate to test the
      # service's branching in isolation. This example deliberately does NOT stub
      # it — target_user owns only the membership being removed, so the whole
      # chain runs for real: destroy! -> should_be_recommended_for_deletion?
      # (0 active memberships, not deleted => genuinely true) ->
      # mark_for_deletion_review! -> deletion_recommended flips and persists.
      it 'sets deletion_recommended on the user through the real method chain' do
        membership # ensure the only membership exists
        expect(target_user.deletion_recommended).to be false

        expect(service.call).to be true

        expect(target_user.reload.deletion_recommended).to be true
      end
    end

    context 'when user should be recommended for deletion' do
      before do
        # Ensure target_user has no other active memberships
        allow(target_user).to receive(:should_be_recommended_for_deletion?).and_return(true)
      end

      it 'marks user for deletion review' do
        expect(target_user).to receive(:mark_for_deletion_review!)
        service.call
      end

      it 'includes deletion recommendation in broadcast' do
        allow(ActiveSupport::Notifications).to receive(:instrument).and_call_original

        expect(ActiveSupport::Notifications).to receive(:instrument)
          .with('membership.removed', hash_including(deletion_recommended: true))
          .and_call_original

        service.call
      end
    end

    context 'when user should not be recommended for deletion' do
      before do
        # Create another active membership for the user
        other_org = create(:organisation)
        ActsAsTenant.with_tenant(other_org) do
          create(:membership, user: target_user, organisation: other_org, active: true)
        end
      end

      it 'does not mark user for deletion review' do
        expect(target_user).not_to receive(:mark_for_deletion_review!)
        service.call
      end

      it 'includes deletion_recommended: false in broadcast' do
        allow(ActiveSupport::Notifications).to receive(:instrument).and_call_original

        expect(ActiveSupport::Notifications).to receive(:instrument)
          .with('membership.removed', hash_including(deletion_recommended: false))
          .and_call_original

        service.call
      end
    end

    context 'permission validation' do
      context 'when admin is not an account admin' do
        let(:regular_user) { create(:user) }

        before do
          ActsAsTenant.with_tenant(organisation) do
            create(:membership, user: regular_user, organisation: organisation, active: true)
          end
        end

        subject(:service) do
          described_class.new(
            membership: membership,
            admin: regular_user
          )
        end

        it 'fails with permission error' do
          expect(service.call).to be false
          expect(service.errors).to include('You do not have permission to remove memberships from this organisation')
        end

        it 'does not remove the membership' do
          # The target membership should still exist after failed removal
          service.call
          expect { membership.reload }.not_to raise_error
        end
      end

      context 'when admin tries to remove their own membership' do
        # NOTE: admin_membership is already defined at the top level
        subject(:service) do
          described_class.new(
            membership: admin_membership,
            admin: admin_user
          )
        end

        it 'fails with self-removal error' do
          expect(service.call).to be false
          expect(service.errors).to include('You cannot remove your own membership')
        end

        it 'does not remove the membership' do
          # Count memberships before the call
          initial_count = Membership.count
          service.call
          # Ensure count remains the same
          expect(Membership.count).to eq(initial_count)
        end
      end
    end

    context 'when membership does not exist' do
      let(:unsaved_membership) do
        ActsAsTenant.with_tenant(organisation) do
          build(:membership, user: target_user, organisation: organisation)
        end
      end

      subject(:service) do
        described_class.new(
          membership: unsaved_membership,
          admin: admin_user
        )
      end

      it 'fails with existence error' do
        expect(service.call).to be false
        expect(service.errors).to include('Membership does not exist')
      end
    end

    context 'database transaction rollback' do
      subject(:service) do
        described_class.new(
          membership: membership,
          admin: admin_user
        )
      end

      before do
        # Mock membership.destroy! to raise an error
        allow(membership).to receive(:destroy!).and_raise(ActiveRecord::RecordInvalid.new(membership))
      end

      it 'rolls back all changes when membership deletion fails' do
        original_deletion_recommended = target_user.deletion_recommended

        service.call

        # User's deletion_recommended status should not change if transaction rolled back
        expect(target_user.reload.deletion_recommended).to eq(original_deletion_recommended)
      end

      it 'returns false and includes error' do
        expect(service.call).to be false
        expect(service.errors).not_to be_empty
      end

      it 'logs the error' do
        expect(Rails.logger).to receive(:error).with(/Failed to remove membership/)
        service.call
      end
    end
  end

  describe 'input validation' do
    it 'requires membership' do
      expect do
        described_class.new(
          membership: nil,
          admin: admin_user
        )
      end.to raise_error(NoMethodError)
    end

    it 'requires admin' do
      ActsAsTenant.with_tenant(organisation) do
        service = described_class.new(
          membership: membership,
          admin: nil
        )

        # Service catches the NoMethodError in rescue block and returns false
        expect(service.call).to be false
        expect(service.errors).not_to be_empty
      end
    end
  end

  describe 'error handling' do
    subject(:service) do
      described_class.new(
        membership: membership,
        admin: admin_user
      )
    end

    it 'handles unexpected errors gracefully' do
      allow(membership).to receive(:destroy!).and_raise(StandardError.new('Unexpected error'))

      expect(service.call).to be false
      expect(service.errors).to include('Unexpected error')
    end

    it 'logs unexpected errors' do
      allow(membership).to receive(:destroy!).and_raise(StandardError.new('Unexpected error'))

      expect(Rails.logger).to receive(:error).with(/Failed to remove membership.*Unexpected error/)

      service.call
    end
  end

  describe 'broadcast event details' do
    subject(:service) do
      described_class.new(
        membership: membership,
        admin: admin_user
      )
    end

    it 'broadcasts complete event information' do
      allow(ActiveSupport::Notifications).to receive(:instrument).and_call_original

      expect(ActiveSupport::Notifications).to receive(:instrument)
        .with('membership.removed', {
                user_id: target_user.id,
                organisation_id: organisation.id,
                admin_id: admin_user.id,
                deletion_recommended: anything,
                removed_at: anything
              })
        .and_call_original

      service.call
    end

    it 'includes current timestamp in broadcast' do
      freeze_time = Time.current

      allow(Time).to receive(:current).and_return(freeze_time)
      allow(ActiveSupport::Notifications).to receive(:instrument).and_call_original

      expect(ActiveSupport::Notifications).to receive(:instrument)
        .with('membership.removed', hash_including(removed_at: freeze_time))
        .and_call_original

      service.call
    end
  end

  # The requester is an admin by role, but their own account is deactivated,
  # so they do not count as the admin who remains (Memberships::LastAdminGuard).
  # Removing the other, last active admin would leave nobody.
  describe 'the last active admin' do
    let(:target_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: target_user, organisation: organisation,
                            role: organisation.find_or_create_account_admin_role, active: true)
      end
    end

    it 'is not removed while the requester cannot act for the organisation' do
      admin_user.update_columns(active: false)
      service = described_class.new(membership: target_membership, admin: admin_user)

      expect(service.call).to be(false)
      expect(service.errors).to include(I18n.t('flash.memberships.last_active_admin', organisation: organisation.name))
      expect(Membership.exists?(target_membership.id)).to be(true)
    end

    it 'is removed while the requester is an active admin' do
      service = described_class.new(membership: target_membership, admin: admin_user)

      expect(service.call).to be(true)
    end
  end
end
