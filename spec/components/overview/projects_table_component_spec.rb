# frozen_string_literal: true

require 'rails_helper'

# What: Overview::ProjectsTableComponent — converted portfolio-table widget.
# Type: Component spec (render_inline; DailyBriefing mocked — presentation + empty state only).
# Why:  Always renders (permission-only); an empty portfolio shows the in-component empty state, not
#       a hidden widget, so an owned-layout slot never collapses for a merely-empty table.
RSpec.describe Overview::ProjectsTableComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:briefing) { instance_double(Dashboard::DailyBriefing) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def build_component
    described_class.new(organisation: organisation, user: user, briefing: briefing)
  end

  it 'always renders (permission-only)' do
    expect(build_component.should_render?).to be true
  end

  describe '#show_billing? (gates the billing-hours columns)' do
    it 'shows the billing columns for a viewer with time access in some project' do
      allow(Current).to receive(:area_access_anywhere?).with(user, organisation, :time_sessions, :read).and_return(true)
      expect(build_component.send(:show_billing?)).to be true
    end

    it 'hides them for a viewer without time access anywhere' do
      allow(Current).to receive(:area_access_anywhere?).with(user, organisation, :time_sessions, :read).and_return(false)
      expect(build_component.send(:show_billing?)).to be false
    end
  end

  it 'shows the empty state when the portfolio is empty' do
    allow(briefing).to receive(:projects_overview).and_return([])
    render_inline(build_component)
    expect(page).to have_text(I18n.t('dashboard.briefing.sections.projects.empty'))
  end

  # The unread column is dropped entirely when no project has unread notifications — an all-"—" column
  # is pure noise. The th/td/footer cells are template-gated on this predicate.
  describe '#show_unread? (gates the unread column)' do
    it 'is true when some project has unread notifications' do
      project = create(:project, organisation: organisation, name: 'Alpha')
      allow(briefing).to receive(:projects_overview).and_return(
        [{ project: project, unread_count: 3, in_billing_hours: 0.0, without_billing_hours: 0.0, last_activity_at: nil }]
      )
      expect(build_component.send(:show_unread?)).to be true
    end

    it 'is false when every project has zero unread (column hidden)' do
      project = create(:project, organisation: organisation, name: 'Alpha')
      allow(briefing).to receive(:projects_overview).and_return(
        [{ project: project, unread_count: 0, in_billing_hours: 1.0, without_billing_hours: 0.0, last_activity_at: nil }]
      )
      expect(build_component.send(:show_unread?)).to be false
    end
  end

  # NOTE: the populated-table render (project name + hour links) uses URL route helpers, which are
  # order-dependently unavailable in ViewComponent's bare render_inline context (a known gotcha; the
  # existing dashboard component specs avoid render_inline for the same reason). That render path is
  # instead covered for real — with working routes — by the briefings request spec, which renders the
  # overview with an actual project. Here we keep the route-free behaviour (should_render? + empty
  # state); duplicating the row render would only re-add the flaky route-helper dependency.
  it 'computes the footer totals from the briefing rows' do
    p1 = create(:project, organisation: organisation, name: 'Alpha')
    p2 = create(:project, organisation: organisation, name: 'Beta')
    allow(briefing).to receive(:projects_overview).and_return(
      [{ project: p1, unread_count: 2, in_billing_hours: 1.5, without_billing_hours: 0.0, last_activity_at: nil },
       { project: p2, unread_count: 3, in_billing_hours: 0.0, without_billing_hours: 2.5, last_activity_at: nil }]
    )
    c = build_component
    expect(c.send(:total_unread)).to eq(5)
    expect(c.send(:total_in_billing)).to eq(1.5)
    expect(c.send(:total_without_billing)).to eq(2.5)
  end

  # The selection filter runs in-memory over the (already policy-scoped) briefing rows: it can only
  # ever narrow that set, so it never surfaces a project the viewer may not see. Each mode is pinned
  # here against a fixed three-project portfolio.
  describe 'project selection mode (#project_rows)' do
    let(:alpha) { create(:project, organisation: organisation, name: 'Alpha') }
    let(:beta)  { create(:project, organisation: organisation, name: 'Beta') }
    let(:gamma) { create(:project, organisation: organisation, name: 'Gamma') }

    def row(project, unread: 0, in_billing: 0.0, without_billing: 0.0)
      { project: project, unread_count: unread, in_billing_hours: in_billing,
        without_billing_hours: without_billing, last_activity_at: nil }
    end

    def component(mode: nil, selected_ids: nil)
      described_class.new(organisation: organisation, user: user, briefing: briefing,
                          mode: mode, selected_ids: selected_ids)
    end

    def projects_in(component)
      component.send(:project_rows).map { |r| r[:project] }
    end

    before do
      # alpha has unread, beta has in-billing hours, gamma has nothing.
      allow(briefing).to receive(:projects_overview).and_return(
        [row(alpha, unread: 2), row(beta, in_billing: 1.5), row(gamma)]
      )
    end

    it 'shows all projects by default (mode nil)' do
      expect(projects_in(component)).to eq([alpha, beta, gamma])
    end

    it 'falls back to all for a forged mode' do
      expect(projects_in(component(mode: 'bogus'))).to eq([alpha, beta, gamma])
    end

    it 'treats the literal "all" mode as no filter (it is not in the whitelist)' do
      # 'all' is what the UI sends for the default; parse strips it, but if it ever reaches the
      # component it must behave as the unfiltered default — not as a forged-but-stored mode.
      expect(projects_in(component(mode: 'all'))).to eq([alpha, beta, gamma])
    end

    describe 'selected' do
      it 'keeps only the chosen project ids' do
        expect(projects_in(component(mode: 'selected', selected_ids: [beta.id]))).to eq([beta])
      end

      it 'drops ids the viewer cannot see (absent from the policy-scoped briefing rows)' do
        stranger = create(:project, organisation: organisation, name: 'Stranger')
        expect(projects_in(component(mode: 'selected', selected_ids: [stranger.id, alpha.id]))).to eq([alpha])
      end

      it 'shows nothing for an empty selection' do
        expect(component(mode: 'selected', selected_ids: []).send(:project_rows)).to be_empty
      end
    end

    describe 'pinned' do
      it 'keeps only projects pinned in the sidebar navigation' do
        user.sidebar_pins.pin_project!(organisation, beta.id)
        expect(projects_in(component(mode: 'pinned'))).to eq([beta])
      end

      it 'shows nothing when no project is pinned' do
        expect(component(mode: 'pinned').send(:project_rows)).to be_empty
      end

      # Cross-org isolation: pins are per-organisation. A project pinned in ANOTHER org must not
      # count as pinned here — this pins that project_pinned? is asked with THIS component's org.
      it 'ignores a pin made in a different organisation' do
        other_org = create(:organisation)
        user.sidebar_pins.pin_project!(other_org, beta.id)
        expect(component(mode: 'pinned').send(:project_rows)).to be_empty
      end
    end

    describe 'with_entries' do
      it 'keeps projects with unread notifications or any not-yet-billed hours' do
        expect(projects_in(component(mode: 'with_entries'))).to eq([alpha, beta])
      end

      it 'counts without_billing hours as entries too' do
        allow(briefing).to receive(:projects_overview).and_return([row(gamma, without_billing: 0.5)])
        expect(projects_in(component(mode: 'with_entries'))).to eq([gamma])
      end

      it 'excludes a project with exactly zero of everything' do
        allow(briefing).to receive(:projects_overview).and_return([row(gamma)])
        expect(component(mode: 'with_entries').send(:project_rows)).to be_empty
      end

      # Smallest-increment boundary: each source at its minimal positive value (1 / 0.1) must still
      # count, and a row at exactly zero must not. This kills both `.positive?` -> `> 1` (the unread:2
      # / 1.5h happy data would survive that) and `.positive?` -> `>= 0` (the zero row would survive).
      it 'is load-bearing per source at the smallest positive increment' do
        zero = create(:project, organisation: organisation, name: 'Zero')
        allow(briefing).to receive(:projects_overview).and_return(
          [row(alpha, unread: 1), row(beta, in_billing: 0.1), row(gamma, without_billing: 0.1), row(zero)]
        )
        expect(projects_in(component(mode: 'with_entries'))).to contain_exactly(alpha, beta, gamma)
      end
    end

    # Build the component the way the editor/render path does — through the registry's extra_params,
    # NOT the constructor directly. This pins the store-shape -> component wiring: extra_params must
    # read 'mode'/'project_ids' and pass them as the mode:/selected_ids: kwargs. Renaming either side
    # (e.g. selected_ids: -> ids:) raises here instead of silently shipping an all-projects table.
    describe 'built through the registry extra_params (store -> render wiring)' do
      def built(widget_hash)
        Dashboards::LayoutEngine.component_for_widget(
          widget_hash, registry: Overview::WidgetRegistry::WIDGETS,
                       organisation: organisation, user: user, briefing: briefing
        )
      end

      it 'wires a stored selected mode + project_ids into the filter' do
        comp = built('key' => 'projects_table', 'mode' => 'selected', 'project_ids' => [beta.id])
        expect(comp.send(:project_rows).map { |r| r[:project] }).to eq([beta])
      end

      it 'wires a stored with_entries mode into the filter' do
        comp = built('key' => 'projects_table', 'mode' => 'with_entries')
        expect(comp.send(:project_rows).map { |r| r[:project] }).to eq([alpha, beta])
      end

      it 'wires a default (modeless) stored widget to the unfiltered table' do
        comp = built('key' => 'projects_table')
        expect(comp.send(:project_rows).map { |r| r[:project] }).to eq([alpha, beta, gamma])
      end
    end
  end

  # Rendered (not via #send) so the component translate runs inside the render pipeline, like the
  # plain empty-state test above. Each mode's empty render explains WHY it is empty.
  describe 'empty-state message (mode-specific)' do
    before { allow(briefing).to receive(:projects_overview).and_return([]) }

    def render_mode(mode:, selected_ids: nil)
      render_inline(described_class.new(organisation: organisation, user: user, briefing: briefing,
                                        mode: mode, selected_ids: selected_ids))
    end

    it 'explains an empty result per mode' do
      render_mode(mode: 'selected', selected_ids: [])
      expect(page).to have_text(I18n.t('dashboard.briefing.sections.projects.empty_selected'))

      render_mode(mode: 'pinned')
      expect(page).to have_text(I18n.t('dashboard.briefing.sections.projects.empty_pinned'))

      render_mode(mode: 'with_entries')
      expect(page).to have_text(I18n.t('dashboard.briefing.sections.projects.empty_with_entries'))

      render_inline(build_component)
      expect(page).to have_text(I18n.t('dashboard.briefing.sections.projects.empty'))
    end
  end
end
