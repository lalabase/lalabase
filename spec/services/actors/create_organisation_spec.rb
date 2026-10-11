# frozen_string_literal: true

require 'rails_helper'

# Actors::CreateOrganisation bootstraps a brand-new organisation: it persists the org,
# ensures its account_admin role, and makes `owner` an active account_admin member —
# all in one transaction, with the tenant cleared (a fresh org has no current tenant yet).
# The 3-step bootstrap is shared with the admin backend via OrganisationBootstrap; this
# spec exercises the web path, where owner == current_user (a real User).
#
# Contract checks: success shape, the three created records, atomic rollback on a failing
# membership, and Current.user restore (no leak).
RSpec.describe Actors::CreateOrganisation, type: :service do
  let(:owner) { create(:user) }

  describe '#call' do
    context 'with a valid new organisation' do
      let(:organisation) { Organisation.new(name: 'Brand New Org') }

      subject(:actor) { described_class.new(organisation: organisation, owner: owner, current_user: owner) }

      it 'returns a successful Result carrying the persisted organisation' do
        result = actor.call

        expect(result).to be_success
        expect(result.resource).to eq(organisation)
        expect(result.resource).to be_persisted
      end

      it 'creates the organisation and the owner membership' do
        expect { actor.call }
          .to change(Organisation, :count).by(1)
          .and change(Membership, :count).by(1)
      end

      it 'makes the owner an active account_admin member' do
        actor.call

        ActsAsTenant.without_tenant do
          membership = owner.memberships.find_by(organisation: organisation)
          expect(membership).to be_present
          expect(membership.active).to be true
          expect(membership.role.title).to eq(Role::ACCOUNT_ADMIN_TITLE)
        end
      end

      it 'restores the previous Current.user afterwards (no leak)' do
        Current.user = nil
        actor.call

        expect(Current.user).to be_nil
      end
    end

    context 'when the organisation is invalid' do
      let(:organisation) { Organisation.new(name: '') }

      subject(:actor) { described_class.new(organisation: organisation, owner: owner, current_user: owner) }

      it 'returns a failure Result with errors' do
        result = actor.call

        expect(result).not_to be_success
        expect(result.errors).to be_present
      end

      it 'creates no organisation' do
        expect { actor.call }.not_to change(Organisation, :count)
      end
    end

    context 'when the membership creation fails after the org was saved' do
      let(:organisation) { Organisation.new(name: 'Rollback Org') }

      subject(:actor) { described_class.new(organisation: organisation, owner: owner, current_user: owner) }

      before do
        allow(owner).to receive_message_chain(:memberships, :create!)
          .and_raise(ActiveRecord::RecordInvalid.new(Membership.new))
      end

      it 'rolls the organisation back (atomic)' do
        expect { actor.call }.not_to change(Organisation, :count)
      end

      it 'returns a failure Result' do
        expect(actor.call).not_to be_success
      end
    end
  end
end
