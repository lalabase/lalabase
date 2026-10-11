# frozen_string_literal: true

require 'rails_helper'

# Guest-Ceiling non-blocking hint (Plan doc/billing_agentur_konto_plan.md §4.3).
#
# What:     a write that leaves a user over the account's configured guest
#           limits must NEVER be blocked -- it must succeed exactly like any
#           other write, but the acting org-admin gets a flash[:warning] hint.
# Why:      §4.3's core decision ("Erkennen & Sichtbar machen statt Blocken")
#           after an adversarial review found the original hard-block design
#           unsafe (wrong rule subject, multiple retroactive write paths).
# Contract: flash[:notice] (success) and flash[:warning] (hint) coexist; the
#           write itself always succeeds regardless of the ceiling.
RSpec.describe 'Guest-Ceiling non-blocking hint', type: :request do
  let(:account) { create(:account, guest_max_organisations: 1) }
  let(:organisation) { create(:organisation, account: account) }
  let(:other_organisation) { create(:organisation, account: account) }

  let(:admin_role) do
    ActsAsTenant.with_tenant(organisation) { create(:admin_role, organisation: organisation) }
  end
  let(:admin) { create(:user) }
  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  let(:guest_role) { ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation, billable: false) } }
  let(:other_guest_role) do
    ActsAsTenant.with_tenant(other_organisation) { create(:role, organisation: other_organisation, billable: false) }
  end
  let(:guest_user) { create(:user) }

  before { sign_in admin }

  describe 'PATCH Organisations::MembershipsController#update' do
    let!(:guest_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: guest_user, organisation: organisation, role: guest_role, active: true)
      end
    end
    let(:other_guest_role_in_org) do
      ActsAsTenant.with_tenant(organisation) { create(:role, organisation: organisation, billable: false) }
    end

    context 'when the user already exceeds guest_max_organisations' do
      before do
        # Guest in TWO organisations of the same account, but the account only allows 1.
        ActsAsTenant.with_tenant(other_organisation) do
          create(:membership, user: guest_user, organisation: other_organisation, role: other_guest_role, active: true)
        end
      end

      it 'still succeeds the update' do
        patch organisation_membership_path(organisation, guest_membership),
              params: { membership: { role_id: other_guest_role_in_org.id } }

        expect(response).to redirect_to(organisation_memberships_path(organisation))
        expect(guest_membership.reload.role_id).to eq(other_guest_role_in_org.id)
      end

      it 'sets a non-blocking flash[:warning] hint alongside the success notice' do
        patch organisation_membership_path(organisation, guest_membership),
              params: { membership: { role_id: other_guest_role_in_org.id } }

        expect(flash[:notice]).to eq(I18n.t('flash.memberships.updated'))
        expect(flash[:warning]).to eq(I18n.t('shared.guest_ceiling.exceeded_hint', user: guest_user.full_name.presence || guest_user.email))
      end
    end

    context 'when the user stays within guest_max_organisations' do
      it 'does not set a flash[:warning] hint' do
        patch organisation_membership_path(organisation, guest_membership),
              params: { membership: { role_id: other_guest_role_in_org.id } }

        expect(flash[:warning]).to be_nil
      end
    end

    # Deploy-time window: T1's account_id column is nullable until
    # Account.backfill_all! (T4) has run. A write against a not-yet-backfilled
    # organisation must degrade to "no hint", never crash the whole request.
    context 'when the organisation predates the Account backfill (account_id nil)' do
      before { organisation.update_column(:account_id, nil) }

      it 'does not raise and simply sets no warning hint' do
        expect do
          patch organisation_membership_path(organisation, guest_membership),
                params: { membership: { role_id: other_guest_role_in_org.id } }
        end.not_to raise_error

        expect(response).to redirect_to(organisation_memberships_path(organisation))
        expect(flash[:warning]).to be_nil
      end
    end

    # The hint runs AFTER the write has committed -- if the detection itself
    # blows up (broken sibling-org data in the same account, timeout), the
    # already-successful change must not turn into a 500. Best-effort by
    # design (§4.3): log and move on.
    context 'when the ceiling detection itself raises' do
      before do
        allow(Subscriptions::GuestCeiling).to receive(:new)
          .and_raise(RuntimeError, 'broken sibling org')
      end

      it 'still completes the write and just skips the hint' do
        patch organisation_membership_path(organisation, guest_membership),
              params: { membership: { role_id: other_guest_role_in_org.id } }

        expect(response).to redirect_to(organisation_memberships_path(organisation))
        expect(guest_membership.reload.role_id).to eq(other_guest_role_in_org.id)
        expect(flash[:warning]).to be_nil
      end
    end
  end

  describe 'POST Organisations::ProjectPermissionsController#create' do
    let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:other_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:target_user) { create(:user) }
    let!(:guest_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: target_user, organisation: organisation, role: guest_role, active: true)
      end
    end
    let(:index_path) { organisation_project_project_permissions_path(organisation, project) }

    context 'when granting a second project pushes the guest over guest_max_projects_per_organisation' do
      before do
        account.update!(guest_max_projects_per_organisation: 1)
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: target_user, project: other_project)
        end
      end

      it 'still creates the project permission' do
        expect do
          post index_path, params: { project_permission: { user_id: target_user.id, tickets_access: 'read_only' } }
        end.to change(ProjectPermission, :count).by(1)
      end

      it 'sets a non-blocking flash[:warning] hint alongside the success notice' do
        post index_path, params: { project_permission: { user_id: target_user.id, tickets_access: 'read_only' } }

        expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.created'))
        expect(flash[:warning]).to eq(I18n.t('shared.guest_ceiling.exceeded_hint', user: target_user.full_name.presence || target_user.email))
      end
    end

    context 'when the guest stays within guest_max_projects_per_organisation' do
      it 'does not set a flash[:warning] hint' do
        post index_path, params: { project_permission: { user_id: target_user.id, tickets_access: 'read_only' } }

        expect(flash[:warning]).to be_nil
      end
    end

    # after_permission_granted is called from BOTH branches of #create (fresh
    # save AND restoring a soft-deleted permission, s. find_or_restore_permission)
    # -- only the fresh-save branch was covered above.
    context 'when restoring a soft-deleted project permission pushes the guest over the limit' do
      before do
        account.update!(guest_max_projects_per_organisation: 1)
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: target_user, project: other_project)
          archived = create(:project_permission, user: target_user, project: project)
          archived.update!(deleted_at: 1.day.ago)
        end
      end

      it 'sets the hint on the restore path too' do
        post index_path, params: { project_permission: { user_id: target_user.id, tickets_access: 'read_only' } }

        expect(flash[:notice]).to eq(I18n.t('flash.project_permissions.restored'))
        expect(flash[:warning]).to eq(I18n.t('shared.guest_ceiling.exceeded_hint', user: target_user.full_name.presence || target_user.email))
      end
    end
  end
end
