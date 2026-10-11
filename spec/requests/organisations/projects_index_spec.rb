# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Organisations::Projects#index', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:user) { create(:user) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  let!(:project_a) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation, name: 'Projekt Alpha')
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  # A project lead: may change project properties (so #archive? passes) but is NOT an
  # account admin (so #unarchive?, #destroy? and the archive page stay closed).
  # tickets_access is not decoration: set_project authorizes :show? BEFORE the action
  # runs, and #show? wants read access in at least one area. A permission row with
  # everything on no_access would bounce this person at the door and the examples would
  # pass for the wrong reason.
  shared_context 'project manager without account-admin rights' do
    let(:manager_role) { create(:role, organisation: organisation, title: 'Projektleitung') }
    let(:manager) { create(:user) }

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: manager, organisation: organisation, role: manager_role, active: true)
        create(:permission, role: manager_role, category: 'projects', action: 'change_project_properties')
        create(:project_permission, user: manager, project: project_a, tickets_access: 'read_write')
      end
      sign_in manager
    end
  end

  # The global projects index no longer renders anything: Organisations::ProjectsController#index
  # is a bare redirect to the organisation root, where the briefing dashboard took over. Fifteen
  # examples here used to assert a 200 and pick apart @total_open_tickets, @projects_stats,
  # @period, @recent_activities, @sees_all_hours and @archived_projects — instance variables of a
  # screen that has not existed for months. They were carried as "known failures" rather than
  # read, which is how they masked real regressions elsewhere in the suite.
  #
  # They are not replaced one-for-one, because the behaviour moved and is covered where it now
  # lives — better than it was here:
  #   * open/overdue/active-work ticket counts, viewer scoping, zero-state
  #       -> spec/services/overview/portfolio_stats_spec.rb
  #   * stats card rendering            -> spec/components/dashboard/stats_cards_component_spec.rb
  #   * period filtering                -> spec/models/concerns/dashboard_periodable_spec.rb
  #   * recent activities               -> spec/services/dashboard/daily_briefing_spec.rb
  #   * widget gating incl. hours access-> spec/requests/organisations/briefings_spec.rb
  #   * archived scoping                -> spec/models/project_spec.rb (scopes :active / :archived)
  #
  # What is NOT covered anywhere else is the handover itself, so that is what stays here.
  describe 'GET /organisations/:id/projects' do
    it 'hands over to the organisation briefing dashboard' do
      get organisation_projects_path(organisation)

      expect(response).to redirect_to(organisation_root_path(organisation))
    end

    it 'hands over for a member without admin rights too, rather than 403ing' do
      standard_role = create(:role, organisation: organisation, title: 'Standard User', is_default: true)
      standard_user = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: standard_user, organisation: organisation, role: standard_role, active: true)
      end
      sign_in standard_user

      get organisation_projects_path(organisation)

      expect(response).to redirect_to(organisation_root_path(organisation))
    end
  end

  # Decision 12 of the plan: both rescue paths in this controller built a URL from
  # @organisation, a variable assigned nowhere in the app. Nothing in the suite walked
  # them, which is why it went unnoticed - a rescue that raises is a 500 exactly where
  # a friendly message was intended.
  describe 'GET show without project access' do
    include_context 'project manager without account-admin rights'

    let!(:foreign_project) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation, name: 'Kein Zugriff')
      end
    end

    it 'redirects with the no-access alert instead of raising' do
      get organisation_project_path(organisation, foreign_project)

      expect(response).to have_http_status(:redirect)
      expect(flash[:alert]).to eq(I18n.t('flash.shared.no_project_access'))
    end
  end

  describe 'PATCH archive' do
    it 'archives the project and sends an account admin to the archive page' do
      patch archive_organisation_project_path(organisation, project_a)
      expect(response).to redirect_to(organisation_archives_path(organisation))
      expect(project_a.reload.archived?).to be true
    end

    # ProjectPolicy#archive? also passes a NON-admin carrying change_project_properties,
    # and the archive page is account-admin only. Sending them there would answer a
    # correct action with "nicht berechtigt", which is worse than the old behaviour.
    context 'as a non-admin who may archive' do
      include_context 'project manager without account-admin rights'

      it 'archives and lands on the briefing, without an authorization alert' do
        patch archive_organisation_project_path(organisation, project_a)

        expect(project_a.reload.archived?).to be true
        expect(response).to redirect_to(organisation_projects_path(organisation))
        expect(flash[:alert]).to be_blank
      end
    end

    # Mirror of the stale restore, and the likelier one: the back button after archiving
    # shows the cached settings page with its "Archivieren" button still there.
    # #archive? answers false for an archived project, so without this branch a correct
    # click on a stale page reads as a rights problem.
    it 'answers a stale archive click with "already archived" instead of a refusal' do
      project_a.archive!(user)

      patch archive_organisation_project_path(organisation, project_a)

      expect(response).to redirect_to(organisation_project_path(organisation, project_a))
      expect(flash[:notice]).to eq(I18n.t('flash.projects.already_archived', name: project_a.name))
      expect(flash[:alert]).to be_blank
    end
  end

  describe 'PATCH unarchive' do
    before do
      project_a.archive!(user)
    end

    it 'unarchives the project and redirects to it' do
      patch unarchive_organisation_project_path(organisation, project_a)
      expect(response).to redirect_to(organisation_project_path(organisation, project_a))
      expect(project_a.reload.archived?).to be false
    end

    # Two admins, one stale page. #unarchive? answers false for a project that is no
    # longer archived, and Pundit would turn that into "nicht berechtigt" - the wrong
    # answer for someone who is allowed but has nothing left to do.
    context 'as a non-admin who may archive but not restore' do
      include_context 'project manager without account-admin rights'

      it 'is refused on an active project rather than told it was already restored' do
        project_a.unarchive!

        patch unarchive_organisation_project_path(organisation, project_a)

        expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
        expect(flash[:notice]).to be_blank
      end
    end

    it 'answers a stale click with "already restored" instead of an authorization error' do
      project_a.unarchive!

      patch unarchive_organisation_project_path(organisation, project_a)

      expect(response).to redirect_to(organisation_archives_path(organisation))
      expect(flash[:notice]).to eq(I18n.t('flash.projects.already_restored', name: project_a.name))
      expect(flash[:alert]).to be_blank
      expect(project_a.reload.archived?).to be false
    end
  end

  describe 'DELETE destroy' do
    before do
      project_a.archive!(user)
    end

    it 'enqueues deletion job for archived projects' do
      delete organisation_project_path(organisation, project_a)
      expect(response).to redirect_to(organisation_projects_path(organisation))
      expect(flash[:notice]).to include('wird im Hintergrund gelöscht')
    end

    it 'redirects for non-archived projects' do
      project_a.unarchive!

      # set_project rescues Pundit::NotAuthorizedError and redirects
      delete organisation_project_path(organisation, project_a)
      expect(response).to have_http_status(:redirect)
    end
  end

  describe 'authentication' do
    it 'redirects unauthenticated users' do
      sign_out user
      get organisation_projects_path(organisation)
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
