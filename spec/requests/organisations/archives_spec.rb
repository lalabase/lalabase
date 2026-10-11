# frozen_string_literal: true

require 'rails_helper'

# "Archivierte Objekte" (doc/archivierte_objekte_plan.md): the one page that leads back
# out of the archive. Before it existed, archiving was a one-way door in practice - the
# sidebar hides archived projects, the projects index redirects to the briefing, and the
# row menu that once carried "Wiederherstellen" was rendered by no view at all.
#
# What this file pins, and why each one is load-bearing:
#   - the gate is ACCOUNT ADMIN, the same one ProjectPolicy#unarchive? demands. A weaker
#     gate would list archived projects to people ProjectPolicy#show? hides them from.
#   - the empty state, because a blank section is the failure mode nobody reports.
#   - a nil `archived_by`, because it is a NORMAL state (optional association, and
#     unarchive! clears it), not an exotic one.
#   - tenant isolation, because the rows come from an org-scoped query rather than a
#     policy scope.
RSpec.describe 'Organisations::Archives', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation, title: 'Standard User', is_default: true) }

  let(:admin) { create(:user) }
  let(:member) { create(:user) }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  let!(:archived_project) do
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation, name: 'Projekt Archiviert')
      project.archive!(admin)
      project
    end
  end

  let!(:active_project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation, name: 'Projekt Aktiv')
    end
  end

  before { ActsAsTenant.current_tenant = organisation }

  describe 'GET index as an account admin' do
    before { sign_in admin }

    # Asserted on the ACTION, not on the bare project name: the layout's sidebar
    # renders every ACTIVE project of the organisation, so a name check against the
    # whole document would fail for a reason that has nothing to do with this page.
    # A restore link, on the other hand, exists only in the archive table.
    it 'lists the archived project and offers no restore action for the active one' do
      get organisation_archives_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Projekt Archiviert')
      expect(response.body).to include(unarchive_organisation_project_path(organisation, archived_project))
      expect(response.body).not_to include(unarchive_organisation_project_path(organisation, active_project))
    end

    it 'links the row to the project settings, where deletion lives' do
      get organisation_archives_path(organisation)

      expect(response.body).to include(edit_organisation_project_path(organisation, archived_project))
    end

    # The whole point of the page, walked end to end: find it again, bring it back,
    # and the row is gone. Anything less proves the list renders, not that it works.
    it 'restores from here and drops the row afterwards' do
      patch unarchive_organisation_project_path(organisation, archived_project)
      expect(archived_project.reload.archived?).to be false

      get organisation_archives_path(organisation)
      # Again the row, not the name: once restored, the project is back in the
      # sidebar, so its NAME is expected in the document. What must be gone is its
      # place in the archive table.
      expect(response.body).not_to include(unarchive_organisation_project_path(organisation, archived_project))
    end

    context 'with nothing archived' do
      before { archived_project.unarchive! }

      it 'renders the empty state rather than a blank section' do
        get organisation_archives_path(organisation)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('views.organisations.archives.index.empty_title'))
      end
    end

    # archived_by is optional and unarchive! clears it, so nil is a normal state, not a
    # corrupt one. The name seam renders the unknown-user label for it; a raw
    # display_name call here would raise on exactly this row.
    context 'when the archiving user is gone' do
      before { archived_project.update!(archived_by: nil) }

      it 'renders the unknown-user label instead of raising' do
        get organisation_archives_path(organisation)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Projekt Archiviert')
        expect(response.body).to include(I18n.t('views.helpers.application.unknown_user'))
      end
    end

    it 'lists the most recently archived project first' do
      older = ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation, name: 'Projekt Zuerst').tap do |project|
          project.archive!(admin)
          project.update!(archived_at: 3.days.ago)
        end
      end

      get organisation_archives_path(organisation)

      newest_row = response.body.index(unarchive_organisation_project_path(organisation, archived_project))
      older_row = response.body.index(unarchive_organisation_project_path(organisation, older))
      expect(newest_row).to be < older_row
    end

    it 'never shows an archived project of another organisation' do
      other_org = create(:organisation)
      ActsAsTenant.with_tenant(other_org) do
        other_admin = create(:user)
        other_role = create(:role, organisation: other_org, title: 'account_admin')
        create(:membership, user: other_admin, organisation: other_org, role: other_role, active: true)
        create(:project, organisation: other_org, name: 'Fremdes Projekt').archive!(other_admin)
      end

      get organisation_archives_path(organisation)

      # Both halves on purpose: a bare absence check would also pass on a page that
      # renders nothing at all.
      expect(response.body).to include('Projekt Archiviert')
      expect(response.body).not_to include('Fremdes Projekt')
    end
  end

  describe 'GET index as a member without account-admin rights' do
    let!(:member_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: member, organisation: organisation, role: member_role, active: true)
      end
    end

    before { sign_in member }

    # Asserted on the refusal, NOT on a fixed target: user_not_authorized uses
    # `redirect_back fallback_location: root_path`, so the destination depends on the
    # Referer header and pinning it would make this example depend on the test client's
    # headers rather than on the policy.
    it 'is refused' do
      get organisation_archives_path(organisation)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
      expect(response.body).not_to include('Projekt Archiviert')
    end
  end
end
