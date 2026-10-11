# frozen_string_literal: true

require 'rails_helper'

# Reduced first-use rendering (style guide "Leerzustände"): while a project
# area holds no records at all, its index page hides the filter/search chrome —
# filters over nothing only add noise. As soon as ONE record exists the chrome
# must be back, even when the current filter/search matches nothing (the
# filtered no-results state keeps the bars so users can loosen the filter).
# Guards both directions for all four areas; the explainer-vs-plain-card branch
# inside the list partials is guarded separately in
# spec/views/organisations/first_time_empty_explainer_spec.rb -- except for the
# time list, whose explainer branch is guarded in
# spec/requests/organisations/time_sessions_empty_reason_spec.rb, because "first
# use" there is a question about the reader and not about the project.
RSpec.describe 'first-use reduced index chrome', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  describe 'tickets index' do
    let(:path) { organisation_project_tickets_path(organisation, project) }

    it 'hides the filter bar while the project has no tickets' do
      get path
      expect(response.body).not_to include('data-controller="filter-bar"')
    end

    it 'shows the filter bar once a ticket exists' do
      ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, organisation: organisation) }
      get path
      expect(response.body).to include('data-controller="filter-bar"')
    end
  end

  describe 'knowledge index' do
    let(:path) { organisation_project_knowledge_index_path(organisation, project) }

    it 'hides the filter bar while the project has no knowledge' do
      get path
      expect(response.body).not_to include('data-controller="filter-bar"')
    end

    it 'shows the filter bar once a note exists' do
      ActsAsTenant.with_tenant(organisation) do
        create(:note, project: project, organisation: organisation, creator: user)
      end
      get path
      expect(response.body).to include('data-controller="filter-bar"')
    end

    # layout.css hides .first-use-empty-card while the detail pane is open
    # (.show-content, e.g. the first-note form) — same master-detail rule as
    # meetings. Only works if the markup keeps these hook classes.
    it 'carries the first-use hook classes the master-detail CSS relies on' do
      get path
      expect(response.body).to include('first-use-empty-grid')
      expect(response.body).to include('first-use-empty-card')
    end
  end

  describe 'meetings index' do
    let(:path) { organisation_project_meetings_path(organisation, project) }
    # The placeholder contains "&" → HTML-escaped in the attribute, so match escaped.
    let(:search_placeholder) { ERB::Util.html_escape(I18n.t('views.organisations.meetings.index.filter_bar.search_placeholder')) }

    it 'hides the search form while the project has no meetings' do
      get path
      expect(response.body).not_to include(search_placeholder)
    end

    it 'shows the search form once a meeting exists' do
      ActsAsTenant.with_tenant(organisation) { create(:meeting, project: project, organisation: organisation) }
      get path
      expect(response.body).to include(search_placeholder)
    end

    # layout.css hides .first-use-empty-card while the detail pane is open
    # (.show-content, e.g. the create-first-meeting form) — the CTA card would
    # prompt for the action already in progress. The rule only works if the
    # markup keeps these hook classes; grep alone would not catch their loss.
    it 'carries the first-use hook classes the master-detail CSS relies on' do
      get path
      expect(response.body).to include('first-use-empty-grid')
      expect(response.body).to include('first-use-empty-card')
    end
  end

  describe 'time sessions index' do
    let(:path) { organisation_time_sessions_path(organisation, project_id_filter: project.id) }

    it 'hides the filter drawer while the reader sees no time sessions' do
      get path
      expect(response.body).not_to include('data-controller="mobile-filter-drawer"')
    end

    it 'shows the filter drawer once a time session exists' do
      ActsAsTenant.with_tenant(organisation) { create(:time_session, project: project, organisation: organisation) }
      get path
      expect(response.body).to include('data-controller="mobile-filter-drawer"')
    end

    # Regression: the first-use CTA lived INSIDE time_sessions_list_frame as a
    # link to #new — Turbo then replaced the frame with "Content missing"
    # (the #new response has no such frame). It must open the inline modal
    # instead, like the header "+" button and the tickets first-use CTA.
    it 'wires the first-use CTA to the inline modal instead of linking into the list frame' do
      get path
      expect(response.body).to include(I18n.t('views.organisations.time_sessions.index_table.empty_first_time_cta'))
      expect(response.body).not_to include(new_organisation_project_time_session_path(organisation, project))
    end

    # Org-wide, "first use" is judged by what THIS reader may see, not by what
    # exists: a bare exists? on the model told a can_view_own user whether the
    # colleagues book here (doc/zeiten_eine_liste_plan.md, decision table).
    context 'for a reader who may only see their own time' do
      let(:own_viewer) { create(:user) }
      let(:colleague) { create(:user) }

      before do
        member_role = create(:role, organisation: organisation)
        create(:membership, user: own_viewer, organisation: organisation, role: member_role, active: true)
        create(:membership, user: colleague, organisation: organisation, role: member_role, active: true)
        create(:time_session_permission, user: own_viewer, project: project, can_view_own: true, can_view_all: false)
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session, project: project, organisation: organisation, creator: colleague)
        end
        sign_in own_viewer
      end

      it 'stays in first use while the colleagues alone have booked' do
        get path
        expect(response.body).not_to include('data-controller="mobile-filter-drawer"')
      end

      it 'leaves first use with the first own booking' do
        ActsAsTenant.with_tenant(organisation) do
          create(:time_session, project: project, organisation: organisation, creator: own_viewer)
        end
        get path
        expect(response.body).to include('data-controller="mobile-filter-drawer"')
      end
    end
  end
end
