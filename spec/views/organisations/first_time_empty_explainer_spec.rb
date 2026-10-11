# frozen_string_literal: true

require 'rails_helper'

# The four project-area lists (Wissen, Tickets, Zeiten, Meetings) pair their
# FIRST-TIME empty state with the plain-language explainer panel
# (shared/_explainer_panel). The filtered "no results" state must stay a plain
# card — an explainer there would lecture users who already use the area.
# These specs render the REAL list partials and guard that branch in both
# directions; rendering for real also surfaces i18n-scope typos as
# missing-translation errors.
RSpec.describe 'first-time empty-state explainer panels', type: :view do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:user) { create(:user) }
  let(:deny_all_policy) { instance_double(ProjectPolicy, area_access?: false) }

  before do
    ActsAsTenant.current_tenant = organisation
    assign(:current_organisation, organisation)
    assign(:project, project)
  end

  after { ActsAsTenant.current_tenant = nil }

  describe 'organisations/knowledge/_knowledge_results' do
    let(:explainer_title) { I18n.t('views.organisations.knowledge.index.explainer.title') }

    def render_results(notes_accessible:)
      without_partial_double_verification do
        allow(view).to receive(:can_access_notes?).and_return(notes_accessible)
        allow(view).to receive(:can_access_documents?).and_return(false)
        # The empty state grew "create note"/"create document" calls to action, so the partial
        # now asks for write permission too. Unstubbed, the render died on the first of them
        # and the example failed for a missing helper rather than for a missing explainer.
        allow(view).to receive(:can_write_notes?).and_return(notes_accessible)
        allow(view).to receive(:can_write_documents?).and_return(false)
      end
      render partial: 'organisations/knowledge/knowledge_results', locals: { knowledge_items: [] }
      rendered
    end

    it 'shows the explainer when the project has no knowledge at all' do
      expect(render_results(notes_accessible: false)).to include(explainer_title)
    end

    it 'shows NO explainer when content exists but the filter matched nothing' do
      create(:note, project: project, organisation: organisation)
      expect(render_results(notes_accessible: true)).not_to include(explainer_title)
    end
  end

  describe 'organisations/tickets/_tickets_results' do
    let(:explainer_title) { I18n.t('views.organisations.tickets.tickets_results.explainer.title') }

    def render_results
      without_partial_double_verification do
        allow(view).to receive(:policy).and_return(deny_all_policy)
        allow(view).to receive(:current_user).and_return(user)
        # Controller helpers the list reads without a defined? guard: the ad-hoc filter
        # (#730) and the selection boxes (#737). A view spec has no controller behind it,
        # so the render died on them before it reached the empty state. No filter is set,
        # and this reader may not write, so there is no box column.
        allow(view).to receive_messages(ad_hoc_filter_params: {}, ticket_list_selectable?: false)
      end
      assign(:view_configuration, ViewConfiguration.for_user_project(user, project, 'tickets'))
      render partial: 'organisations/tickets/tickets_results',
             locals: { tickets: [], project: project, sortable_header: false }
      rendered
    end

    it 'shows the explainer when the project has no tickets at all' do
      expect(render_results).to include(explainer_title)
    end

    it 'shows NO explainer when tickets exist but the filter matched nothing' do
      create(:ticket, project: project, organisation: organisation)
      expect(render_results).not_to include(explainer_title)
    end
  end

  # The TIME LIST used to be guarded here too, and had been red since the
  # project's own times page became one organisation-wide list (#675): it passed
  # a `project:` local the partial stopped declaring. Nobody saw it, because this
  # file does not run in CI.
  #
  # It is not repaired but MOVED, because it cannot be answered here. "First use"
  # on that list is not "does this project hold time" but "may THIS reader see
  # any", which lives on the controller (#time_sessions_first_use?) -- a view
  # spec could only reach it by stubbing the very predicate under test, and would
  # then assert its own stub. Both directions are guarded over HTTP instead:
  # spec/requests/organisations/time_sessions_empty_reason_spec.rb ("what it
  # leaves alone") and first_use_reduced_chrome_spec.rb, both in the CI list.

  describe 'organisations/meetings/_meetings_results' do
    before { assign(:pagy, Pagy.new(count: 0)) }
    let(:explainer_title) { I18n.t('views.organisations.meetings.index.explainer.title') }

    def render_results
      without_partial_double_verification do
        allow(view).to receive(:policy).and_return(deny_all_policy)
      end
      render partial: 'organisations/meetings/meetings_results',
             locals: { meetings: [], selected_meeting: nil }
      rendered
    end

    it 'shows the explainer when the project has no meetings at all' do
      expect(render_results).to include(explainer_title)
    end

    it 'shows NO explainer when meetings exist but the search matched nothing' do
      create(:meeting, project: project, organisation: organisation)
      expect(render_results).not_to include(explainer_title)
    end
  end
end
