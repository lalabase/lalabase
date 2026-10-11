# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the org-wide "Zeiten" capture modal.
#
# The org-wide create posts to organisation_time_sessions_path WITHOUT a project in the
# route — the chosen project arrives inside the form as time_session[project_id]. set_project_if_present
# previously read only params[:project_id], so @project stayed nil and the before_action
# :authorize_time_session_write redirected (302) BEFORE #create ran: the entry was silently
# dropped with no error surfaced in the Turbo modal.
#
# This exercises the full before_action chain (set_project_if_present ->
# authorize_time_session_write -> create), which the controller-unit test of
# set_project_if_present cannot, and which is the level the symptom actually lived at.
RSpec.describe 'Organisations::TimeSessions create', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let(:valid_attributes) do
    { duration_string: '0:15', occurred_on: Date.current.to_s, description: 'Org-weit erfasst' }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  # acts_as_tenant resets the current tenant after each request, so a bare
  # `change(TimeSession, :count)` measures the after-count untenanted. Evaluate both
  # ends inside the org tenant.
  def time_session_count
    ActsAsTenant.with_tenant(organisation) { TimeSession.count }
  end

  describe 'POST org-wide (Zeiten), project supplied in the form' do
    it 'creates the time session, resolving the project from time_session[project_id]' do
      expect do
        post organisation_time_sessions_path(organisation),
             params: { time_session: valid_attributes.merge(project_id: project.id) }
      end.to change { time_session_count }.by(1)

      ActsAsTenant.with_tenant(organisation) do
        created = TimeSession.order(:created_at).last
        expect(created.project).to eq(project)
        expect(created.duration).to eq(15)
        expect(created.creator).to eq(user)
      end
    end

    it 'does not get rejected by authorize_time_session_write with a "select a project" alert' do
      post organisation_time_sessions_path(organisation),
           params: { time_session: valid_attributes.merge(project_id: project.id) }

      # The bug set flash[:alert] = select_project and redirected before #create ran.
      expect(flash[:alert]).to be_blank
    end
  end

  # The modal sends through Turbo since 28.09.2026: a refused save answered without
  # Turbo was the bare form on an unstyled page.
  describe 'POST org-wide through Turbo, as the modal sends it' do
    let(:turbo_headers) { { 'Accept' => 'text/vnd.turbo-stream.html, text/html' } }
    let(:modal_params) { { context: 'index_page', answer_with_page: '1' } }

    it 'answers a save with the list page, not with the list stream' do
      post organisation_time_sessions_path(organisation),
           params: modal_params.merge(time_session: valid_attributes.merge(project_id: project.id)),
           headers: turbo_headers

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(organisation_time_sessions_path(organisation, project_id_filter: project.id))
    end

    it 'answers a refused save with the errors as a stream into the open form' do
      post organisation_time_sessions_path(organisation),
           params: modal_params.merge(time_session: valid_attributes.merge(project_id: project.id, duration_string: '')),
           headers: turbo_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('time-session-error-container')
    end
  end

  describe 'POST project-scoped (project in the route)' do
    it 'still creates the time session' do
      expect do
        post organisation_project_time_sessions_path(organisation, project),
             params: { time_session: valid_attributes }
      end.to change { time_session_count }.by(1)
    end
  end

  # T3 R1 (plan doc/actors_t3_save_time_session_plan.md §4, failing-first): the
  # pre-actor controller created the session and silently copied group.billed?
  # onto it — a billed group id in the POST invoiced the session on creation.
  describe 'T3 R1: POST with a billed target group' do
    let(:billed_group) do
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session_group, :billed, organisation: organisation, creator: user)
      end
    end

    it 'refuses with 422 and creates no session' do
      expect do
        post organisation_project_time_sessions_path(organisation, project),
             params: { time_session: valid_attributes.merge(time_session_group_id: billed_group.id) }
      end.not_to(change { time_session_count })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('services.save_time_session.group_billed'))
    end
  end
end
