# frozen_string_literal: true

require 'rails_helper'

# What:  DashboardHelper — the render-side glue for the auto-columns dashboard.
# Type:  Helper unit specs (no browser; component_for_widget stubbed for the owner branch).
# Why:   The layout model is "split-pane": a row is a 6-unit flex track and every row is rendered
#        FULL (Σ units == ROW_UNITS), so the visible width equals the unit proportion. These specs
#        pin the contract the views depend on: the unit→flex-class map, the widget label, the
#        owner-aware slot plan WITH its unit distribution, and the edit-side helpers.
# Contracts:
#   - dashboard_unit_flex maps 1..6 → a flex utility, anything else → the 1-unit fallback.
#   - dashboard_row_slots distributes units across the VISIBLE slots so they sum to ROW_UNITS, holds
#     a placeholder for a gated widget in an OWNED layout, omits it in an inherited one, and never
#     mutates the row.
RSpec.describe DashboardHelper, type: :helper do
  describe '#dashboard_unit_flex' do
    it 'maps each unit count to its proportional flex utility' do
      expect(helper.dashboard_unit_flex(1)).to eq('lg:flex-[1_1_0%]')
      expect(helper.dashboard_unit_flex(3)).to eq('lg:flex-[3_1_0%]')
      expect(helper.dashboard_unit_flex(6)).to eq('lg:flex-[6_1_0%]')
    end

    # An out-of-range or absent width must never render no class (a flex item with no basis collapses):
    # it falls back to the 1-unit utility.
    it 'falls back to the 1-unit utility for an out-of-range value' do
      expect(helper.dashboard_unit_flex(0)).to eq(helper.dashboard_unit_flex(1))
      expect(helper.dashboard_unit_flex(7)).to eq(helper.dashboard_unit_flex(1))
      expect(helper.dashboard_unit_flex(nil)).to eq(helper.dashboard_unit_flex(1))
    end
  end

  describe '#dashboard_widget_label' do
    it 'returns the registry i18n label for a known widget' do
      expect(helper.dashboard_widget_label('recent_tickets')).to eq(I18n.t('dashboard.widgets.recent_tickets'))
    end

    it 'humanizes an unknown key instead of raising' do
      expect(helper.dashboard_widget_label('made_up_widget')).to eq('Made up widget')
    end
  end

  # The owner-aware render branch (§5/§15): an OWNED config holds a placeholder in a gated slot,
  # an inherited default omits it so the row reflows. component_for_widget is stubbed so the branch
  # is tested in isolation from real permission setup; widget_units/min come from the real registry.
  describe '#dashboard_row_slots' do
    let(:project) { double('project') }
    let(:user) { double('user') }
    let(:visible) { double('visible component', should_render?: true) }
    let(:gated)   { double('gated component', should_render?: false) }
    # recent_tickets + recent_notes both have a 2-unit minimum, so a full row distributes to 3 + 3.
    let(:row) { { 'widgets' => [{ 'key' => 'recent_tickets' }, { 'key' => 'recent_notes' }] } }

    before do
      allow(Dashboards::LayoutEngine).to receive(:component_for_widget) do |widget, **|
        widget['key'] == 'recent_tickets' ? gated : visible
      end
    end

    context 'when the layout is the user own config (owned: true)' do
      it 'holds a placeholder slot for the gated widget and keeps the visible one' do
        slots = helper.dashboard_row_slots(row, project: project, user: user, owned: true)

        expect(slots.size).to eq(2)
        expect(slots.first).to have_attributes(placeholder: true, component: nil)
        expect(slots.last).to have_attributes(placeholder: false, component: visible)
      end

      it 'distributes the units across the held slots so the row is full (Σ == ROW_UNITS)' do
        slots = helper.dashboard_row_slots(row, project: project, user: user, owned: true)

        expect(slots.sum(&:units)).to eq(Dashboards::LayoutEngine::ROW_UNITS)
        expect(slots.map(&:units)).to eq([3, 3])
      end

      it 'does not mutate the row (permission + distribution are render-time, not persistence)' do
        snapshot = Marshal.load(Marshal.dump(row))
        helper.dashboard_row_slots(row, project: project, user: user, owned: true)
        expect(row).to eq(snapshot)
      end
    end

    context 'when the layout is an inherited default (owned: false)' do
      it 'omits the gated widget so the surviving one reflows to the full row' do
        slots = helper.dashboard_row_slots(row, project: project, user: user, owned: false)

        expect(slots.size).to eq(1)
        expect(slots.first).to have_attributes(placeholder: false, component: visible)
        # The dropped widget's width is redistributed: the survivor fills the whole row.
        expect(slots.first.units).to eq(Dashboards::LayoutEngine::ROW_UNITS)
      end

      it 'redistributes a dropped widget width across the remaining survivors (still Σ == ROW_UNITS)' do
        # Three widgets, the gated one (recent_tickets) is dropped for an inherited layout; the two
        # survivors must absorb its width and still fill the row, not leave a gap.
        three = { 'widgets' => [{ 'key' => 'recent_tickets' }, { 'key' => 'recent_notes' }, { 'key' => 'team_members' }] }
        slots = helper.dashboard_row_slots(three, project: project, user: user, owned: false)

        expect(slots.size).to eq(2)
        expect(slots.sum(&:units)).to eq(Dashboards::LayoutEngine::ROW_UNITS)
        expect(slots.map(&:units)).to eq([3, 3]) # the dropped widget's units redistributed to the survivors
      end
    end

    it 'honours a stored width above the minimum when distributing' do
      # recent_tickets pinned to 4 + recent_notes (min 2) already sums to 6 → kept as-is.
      wide = { 'widgets' => [{ 'key' => 'recent_tickets', 'units' => 4 }, { 'key' => 'recent_notes' }] }
      slots = helper.dashboard_row_slots(wide, project: project, user: user, owned: true)
      expect(slots.map(&:units)).to eq([4, 2])
    end

    it 'drops widgets that resolve to no component (unknown/undrawable)' do
      allow(Dashboards::LayoutEngine).to receive(:component_for_widget).and_return(nil)
      slots = helper.dashboard_row_slots(row, project: project, user: user, owned: true)
      expect(slots).to be_empty
    end

    it 'skips a blank widget entry without trying to build a component for it' do
      # Drop the `next if widget.blank?` guard and component_for_widget(nil) is called — the stub
      # below would crash on nil['key']. So this pins that blanks are skipped before that call.
      blanky = { 'widgets' => [nil, { 'key' => 'recent_notes' }] }
      slots = helper.dashboard_row_slots(blanky, project: project, user: user, owned: true)
      expect(slots.length).to eq(1)
      expect(slots.first.component).to eq(visible)
    end
  end

  # The editor reads its widget list through this: legacy string entries become hashes, blanks drop.
  describe '#dashboard_edit_widgets' do
    it 'normalizes legacy string entries to widget hashes' do
      expect(helper.dashboard_edit_widgets(['recent_tickets'])).to eq([{ 'key' => 'recent_tickets' }])
    end

    it 'keeps hash entries and drops blanks' do
      expect(helper.dashboard_edit_widgets([nil, { 'key' => 'a' }, ''])).to eq([{ 'key' => 'a' }])
    end

    it 'returns an empty array for a nil widget list' do
      expect(helper.dashboard_edit_widgets(nil)).to eq([])
    end
  end

  # The serialization shape the whole submit/reindex path depends on (mirrored in the JS reindex).
  describe '#dashboard_widget_field_prefix' do
    it 'builds the rows[i][widgets][j] field-name prefix' do
      expect(helper.dashboard_widget_field_prefix(0, 1)).to eq('rows[0][widgets][1]')
    end
  end
end
