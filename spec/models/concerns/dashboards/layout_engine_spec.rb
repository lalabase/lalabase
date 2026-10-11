# frozen_string_literal: true

require 'rails_helper'

# What:  Dashboards::LayoutEngine — the registry + resolution logic behind the auto-columns dashboard.
# Type:  Module unit specs (real registry; DB-backed for resolve_layout).
# Why:   The width model is units-on-a-6-track ("split-pane"): each widget has a minimum width in
#        1/6-of-a-row units, rows fill to ROW_UNITS. These specs pin the registry contract, the
#        width helpers (widget_units / widget_min_units / distribute_row_units), the param→widget
#        builder, the no-access predicate, and the unchanged key/normalize/component/resolve logic.
RSpec.describe Dashboards::LayoutEngine do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'Constants' do
    describe 'ROW_UNITS' do
      it 'is a positive integer track size' do
        expect(described_class::ROW_UNITS).to be_a(Integer)
        expect(described_class::ROW_UNITS).to be > 0
      end
    end

    describe 'WIDGET_REGISTRY' do
      it 'has required keys for every widget' do
        described_class::WIDGET_REGISTRY.each do |key, config|
          expect(config).to have_key(:label_key), "#{key} missing :label_key"
          expect(config).to have_key(:component), "#{key} missing :component"
          expect(config).to have_key(:units), "#{key} missing :units"
          expect(config).to have_key(:permission), "#{key} missing :permission"
        end
      end

      # :units is the widget's MINIMUM width; it backs both the model validation and the editor's
      # distribution. A value outside [1, ROW_UNITS] would silently break the layout math.
      it 'declares an integer minimum width within [1, ROW_UNITS] for every widget' do
        described_class::WIDGET_REGISTRY.each do |key, config|
          expect(config[:units]).to be_a(Integer), "#{key} :units not an Integer"
          expect(config[:units]).to be_between(1, described_class::ROW_UNITS),
                                    "#{key} :units outside [1, #{described_class::ROW_UNITS}]"
        end
      end

      it 'has callable extra_params lambdas where defined' do
        described_class::WIDGET_REGISTRY.each do |key, config|
          next unless config[:extra_params]

          expect(config[:extra_params]).to respond_to(:call), "#{key} :extra_params is not callable"
        end
      end

      it 'has callable normalize lambdas where defined' do
        described_class::WIDGET_REGISTRY.each do |key, config|
          next unless config[:normalize]

          expect(config[:normalize]).to respond_to(:call), "#{key} :normalize is not callable"
        end
      end
    end

    describe 'SYSTEM_DEFAULT_LAYOUT' do
      it 'references only registered widgets' do
        described_class::SYSTEM_DEFAULT_LAYOUT.each do |row|
          row['widgets'].each do |widget_key|
            base_key, _param = described_class.parse_widget_key(widget_key)
            expect(described_class::WIDGET_REGISTRY).to have_key(base_key),
                                                        "Widget '#{base_key}' is not registered in WIDGET_REGISTRY"
          end
        end
      end

      # Every default row must be satisfiable: the sum of its widgets' minimum widths has to fit the
      # track, otherwise the row could never be rendered full.
      it 'keeps each row within ROW_UNITS at minimum widths' do
        described_class::SYSTEM_DEFAULT_LAYOUT.each_with_index do |row, idx|
          min_sum = row['widgets'].sum { |w| described_class.widget_min_units(w) }
          expect(min_sum).to be <= described_class::ROW_UNITS,
                             "Row #{idx + 1} minimum widths (#{min_sum}) exceed ROW_UNITS"
        end
      end

      it 'is frozen' do
        expect(described_class::SYSTEM_DEFAULT_LAYOUT).to be_frozen
      end
    end
  end

  describe '.parse_widget_key' do
    it 'splits key and parameter on first colon' do
      base, param = described_class.parse_widget_key('smart_folder_tickets:folder-id')
      expect(base).to eq('smart_folder_tickets')
      expect(param).to eq('folder-id')
    end

    it 'returns nil param for simple keys' do
      base, param = described_class.parse_widget_key('recent_tickets')
      expect(base).to eq('recent_tickets')
      expect(param).to be_nil
    end

    it 'returns [nil, nil] for nil input' do
      base, param = described_class.parse_widget_key(nil)
      expect(base).to be_nil
      expect(param).to be_nil
    end

    it 'returns [nil, nil] for empty string' do
      base, param = described_class.parse_widget_key('')
      expect(base).to be_nil
      expect(param).to be_nil
    end

    it 'preserves everything after first colon (multiple colons)' do
      base, param = described_class.parse_widget_key('widget:param:extra:stuff')
      expect(base).to eq('widget')
      expect(param).to eq('param:extra:stuff')
    end

    it 'converts symbol input to string' do
      base, param = described_class.parse_widget_key(:recent_tickets)
      expect(base).to eq('recent_tickets')
      expect(param).to be_nil
    end

    it 'returns nil param when colon is at end (trailing colon)' do
      base, param = described_class.parse_widget_key('widget:')
      expect(base).to eq('widget')
      expect(param).to be_nil
    end
  end

  describe '.normalize_widget' do
    it 'converts a simple string to hash' do
      expect(described_class.normalize_widget('recent_tickets')).to eq({ 'key' => 'recent_tickets' })
    end

    it 'parses smart_folder_tickets with folder_id' do
      result = described_class.normalize_widget('smart_folder_tickets:abc-123')
      expect(result).to eq({ 'key' => 'smart_folder_tickets', 'folder_id' => 'abc-123' })
    end

    it 'parses stats_cards with multiple card keys' do
      result = described_class.normalize_widget('stats_cards:tickets,notes')
      expect(result).to eq({ 'key' => 'stats_cards', 'cards' => [{ 'key' => 'tickets' }, { 'key' => 'notes' }] })
    end

    it 'parses stats_cards with single card key' do
      result = described_class.normalize_widget('stats_cards:tickets')
      expect(result).to eq({ 'key' => 'stats_cards', 'cards' => [{ 'key' => 'tickets' }] })
    end

    it 'returns empty hash for nil input' do
      expect(described_class.normalize_widget(nil)).to eq({})
    end

    it 'returns empty hash for empty string input' do
      expect(described_class.normalize_widget('')).to eq({})
    end

    it 'ignores param for widgets without normalizer' do
      expect(described_class.normalize_widget('recent_tickets:some-param')).to eq({ 'key' => 'recent_tickets' })
    end

    it 'ignores param for unknown widgets' do
      expect(described_class.normalize_widget('unknown_widget:param')).to eq({ 'key' => 'unknown_widget' })
    end

    it 'returns base key only for smart_folder_tickets without param' do
      expect(described_class.normalize_widget('smart_folder_tickets')).to eq({ 'key' => 'smart_folder_tickets' })
    end

    it 'returns base key only for stats_cards without param' do
      expect(described_class.normalize_widget('stats_cards')).to eq({ 'key' => 'stats_cards' })
    end
  end

  describe '.widget_min_units' do
    it 'returns the registered minimum for a known widget' do
      expect(described_class.widget_min_units({ 'key' => 'recent_tickets' })).to eq(2)
      expect(described_class.widget_min_units({ 'key' => 'stats_cards' })).to eq(1)
    end

    it 'reads the key from a legacy string widget' do
      expect(described_class.widget_min_units('recent_tickets')).to eq(2)
    end

    it 'defaults to 1 for an unknown or nil widget' do
      expect(described_class.widget_min_units({ 'key' => 'nope' })).to eq(1)
      expect(described_class.widget_min_units(nil)).to eq(1)
    end
  end

  # widget_units is the single definition of a widget's width shared by the Σ-units validation and
  # the render helpers, so they can never disagree on what an absent/invalid width means.
  describe '.widget_units' do
    it 'returns a stored width above the minimum' do
      expect(described_class.widget_units({ 'key' => 'recent_tickets', 'units' => 4 })).to eq(4)
    end

    it 'defaults to the type minimum when no width is stored' do
      expect(described_class.widget_units({ 'key' => 'recent_tickets' })).to eq(2) # min 2
      expect(described_class.widget_units({ 'key' => 'stats_cards' })).to eq(1)    # min 1
    end

    it 'reads the legacy span key as a width fallback' do
      expect(described_class.widget_units({ 'key' => 'recent_tickets', 'span' => 3 })).to eq(3)
    end

    it 'clamps a stored width into [min, ROW_UNITS]' do
      expect(described_class.widget_units({ 'key' => 'recent_tickets', 'units' => 1 })).to eq(2) # up to min
      expect(described_class.widget_units({ 'key' => 'stats_cards', 'units' => 99 })).to eq(described_class::ROW_UNITS)
    end

    it 'defaults for a non-positive or non-integer width' do
      expect(described_class.widget_units({ 'key' => 'stats_cards', 'units' => 0 })).to eq(1)
      expect(described_class.widget_units({ 'key' => 'stats_cards', 'units' => '2' })).to eq(1)
    end

    it 'defaults for legacy string and nil widgets without crashing' do
      expect(described_class.widget_units('recent_tickets')).to eq(2)
      expect(described_class.widget_units(nil)).to eq(1)
    end
  end

  # distribute_row_units enforces the split-pane invariant: a row's widths always sum to ROW_UNITS.
  # Mirrors the JS normalizeRow, so server render and inline editor produce identical widths.
  describe '.distribute_row_units' do
    it 'grows an under-full row round-robin from the left' do
      expect(described_class.distribute_row_units([2, 2], [2, 2])).to eq([3, 3])
      expect(described_class.distribute_row_units([2, 2, 1], [2, 2, 1])).to eq([3, 2, 1])
    end

    it 'fills a single widget to the whole track' do
      expect(described_class.distribute_row_units([2], [2])).to eq([described_class::ROW_UNITS])
    end

    it 'leaves an already-full row unchanged (explicit widths preserved)' do
      expect(described_class.distribute_row_units([4, 2], [2, 2])).to eq([4, 2])
    end

    it 'shrinks an over-full row from the right toward each minimum' do
      expect(described_class.distribute_row_units([4, 4], [2, 2])).to eq([4, 2])
    end

    it 'walks right-to-left across several widgets, stopping each at its minimum' do
      # [4,4,2] over by 4: rightmost (already at min 2) is skipped, the middle drops 4->2, then the
      # left drops 4->2 and STOPS there (its min is 1) because the surplus is exhausted. Pins the
      # multi-element continuation branch of the shrink loop.
      expect(described_class.distribute_row_units([4, 4, 2], [1, 2, 2])).to eq([2, 2, 2])
    end

    it 'cannot shrink below the minimums (degenerate over-subscribed row left as-is)' do
      expect(described_class.distribute_row_units([2, 2, 2, 2], [2, 2, 2, 2])).to eq([2, 2, 2, 2])
    end

    it 'returns an empty array for an empty row' do
      expect(described_class.distribute_row_units([], [])).to eq([])
    end
  end

  # build_widget turns submitted per-widget params into the stored widget hash. Shared by the layout
  # save and the live widget_preview, so a preview can never parse settings differently than the save.
  describe '.build_widget' do
    it 'returns nil for a blank or missing key' do
      expect(described_class.build_widget({ key: '' })).to be_nil
      expect(described_class.build_widget({ key: nil })).to be_nil
    end

    it 'stores a width only when it exceeds the type minimum (the minimum is the default)' do
      expect(described_class.build_widget({ key: 'recent_tickets', units: '4' })).to eq({ 'key' => 'recent_tickets', 'units' => 4 })
      expect(described_class.build_widget({ key: 'recent_tickets', units: '2' })).to eq({ 'key' => 'recent_tickets' })
    end

    it 'carries the smart folder id' do
      expect(described_class.build_widget({ key: 'smart_folder_tickets', folder_id: 'abc' }))
        .to eq({ 'key' => 'smart_folder_tickets', 'folder_id' => 'abc' })
    end

    it 'carries recent_tickets display + period' do
      expect(described_class.build_widget({ key: 'recent_tickets', display: 'list', period: 'this_week' }))
        .to eq({ 'key' => 'recent_tickets', 'display' => 'list', 'period' => 'this_week' })
    end

    it 'parses stats card keys and per-card settings, dropping blanks' do
      widget = described_class.build_widget({
                                              key: 'stats_cards',
                                              card_keys: ['tickets', '', 'notes'],
                                              card_settings: { 'tickets' => { period: 'this_week' } }
                                            })
      expect(widget).to eq({
                             'key' => 'stats_cards',
                             'cards' => [{ 'key' => 'tickets', 'period' => 'this_week' }, { 'key' => 'notes' }]
                           })
    end
  end

  # no-access drives the "you lack the right" placeholder. True only when a widget HAS a permission
  # the viewer lacks; permission-free and unknown widgets are never gated.
  describe '.widget_no_access?' do
    it 'is true for a permissioned widget absent from the available set' do
      expect(described_class.widget_no_access?('recent_tickets', {})).to be(true)
    end

    it 'is false for a permissioned widget that IS available' do
      expect(described_class.widget_no_access?('recent_tickets', { 'recent_tickets' => {} })).to be(false)
    end

    it 'is false for a permission-free widget regardless of the set' do
      expect(described_class.widget_no_access?('stats_cards', {})).to be(false)
    end

    it 'is false for an unknown widget key' do
      expect(described_class.widget_no_access?('nope', {})).to be(false)
    end
  end

  describe '.component_for_widget' do
    it 'creates RecentTicketsComponent with display and period' do
      widget_data = { 'key' => 'recent_tickets', 'display' => 'list', 'period' => 'this_week' }
      component = described_class.component_for_widget(widget_data, project: project, user: user)
      expect(component).to be_a(Dashboard::RecentTicketsComponent)
    end

    it 'creates StatsCardsComponent with card_settings' do
      widget_data = { 'key' => 'stats_cards', 'cards' => [{ 'key' => 'tickets' }] }
      component = described_class.component_for_widget(widget_data, project: project, user: user)
      expect(component).to be_a(Dashboard::StatsCardsComponent)
    end

    it 'creates SmartFolderTicketsComponent with folder_id' do
      widget_data = { 'key' => 'smart_folder_tickets', 'folder_id' => 'some-uuid' }
      component = described_class.component_for_widget(widget_data, project: project, user: user)
      expect(component).to be_a(Dashboard::SmartFolderTicketsComponent)
    end

    it 'creates generic component without extra params' do
      component = described_class.component_for_widget({ 'key' => 'notifications' }, project: project, user: user)
      expect(component).to be_a(Dashboard::NotificationsComponent)
    end

    it 'handles legacy string format' do
      component = described_class.component_for_widget('recent_notes', project: project, user: user)
      expect(component).to be_a(Dashboard::RecentNotesComponent)
    end

    it 'handles legacy string with parameter' do
      component = described_class.component_for_widget('smart_folder_tickets:folder-uuid', project: project, user: user)
      expect(component).to be_a(Dashboard::SmartFolderTicketsComponent)
    end

    it 'returns nil for unknown widget key' do
      expect(described_class.component_for_widget({ 'key' => 'nonexistent' }, project: project, user: user)).to be_nil
    end

    it 'returns nil for blank key' do
      expect(described_class.component_for_widget({ 'key' => '' }, project: project, user: user)).to be_nil
    end

    it 'returns nil for nil key in hash' do
      expect(described_class.component_for_widget({ 'key' => nil }, project: project, user: user)).to be_nil
    end

    it 'returns nil for nil input' do
      expect(described_class.component_for_widget(nil, project: project, user: user)).to be_nil
    end

    it 'returns nil for non-Hash non-String input' do
      expect(described_class.component_for_widget(42, project: project, user: user)).to be_nil
      expect(described_class.component_for_widget([], project: project, user: user)).to be_nil
      expect(described_class.component_for_widget(true, project: project, user: user)).to be_nil
    end

    it 'returns nil for Hash without key field' do
      expect(described_class.component_for_widget({ 'folder_id' => 'abc' }, project: project, user: user)).to be_nil
    end

    it 'returns nil and logs warning when component class does not exist' do
      fake_registry = described_class::WIDGET_REGISTRY.merge(
        'fake_widget' => { label_key: 'dashboard.widgets.fake', component: 'Dashboard::NonExistentComponent', units: 1, permission: nil }
      )
      stub_const('Dashboards::LayoutEngine::WIDGET_REGISTRY', fake_registry)

      expect(Rails.logger).to receive(:warn).with(/NonExistentComponent/)
      expect(described_class.component_for_widget({ 'key' => 'fake_widget' }, project: project, user: user)).to be_nil
    end

    it 'creates each registered widget type successfully' do
      described_class::WIDGET_REGISTRY.each_key do |key|
        component = described_class.component_for_widget({ 'key' => key }, project: project, user: user)
        expect(component).not_to be_nil, "Failed to create component for registered widget '#{key}'"
      end
    end
  end

  describe '.available_widgets_for' do
    let(:policy) { instance_double(ProjectPolicy) }

    before { allow(ProjectPolicy).to receive(:new).with(user, project).and_return(policy) }

    it 'returns all widgets when user has full permissions' do
      allow(policy).to receive(:area_access?).and_return(true)

      widgets = described_class.available_widgets_for(user, project)
      expect(widgets.keys).to match_array(described_class::WIDGET_REGISTRY.keys)
    end

    it 'returns only permission-free widgets when user has no permissions' do
      allow(policy).to receive(:area_access?).and_return(false)

      widgets = described_class.available_widgets_for(user, project)
      permission_free = described_class::WIDGET_REGISTRY.select { |_, c| c[:permission].nil? }.keys
      expect(widgets.keys).to match_array(permission_free)
    end

    it 'selectively includes widgets based on specific permissions' do
      allow(policy).to receive(:area_access?).and_return(false)
      allow(policy).to receive(:area_access?).with(:tickets, :read).and_return(true)

      widgets = described_class.available_widgets_for(user, project)

      expect(widgets.keys).to include('recent_tickets', 'smart_folder_tickets')
      expect(widgets.keys).not_to include('recent_notes', 'team_members', 'time_tracking')
      expect(widgets.keys).to include('stats_cards', 'notifications', 'project_info')
    end

    it 'preserves widget config hashes in the returned result' do
      allow(policy).to receive(:area_access?).and_return(true)

      widgets = described_class.available_widgets_for(user, project)
      widgets.each do |key, config|
        expect(config).to eq(described_class::WIDGET_REGISTRY[key])
      end
    end
  end

  describe '.resolve_layout' do
    it 'returns user config when available' do
      user_layout = [{ 'widgets' => %w[recent_tickets recent_notes] }]
      create(:dashboard_configuration, user: user, project: project, organisation: organisation, layout: user_layout)

      expect(described_class.resolve_layout(user, project)).to eq(user_layout)
    end

    it 'falls back to project default when no user config' do
      default_layout = [{ 'widgets' => ['stats_cards'] }]
      create(:dashboard_configuration, :project_default, project: project, organisation: organisation, layout: default_layout)

      expect(described_class.resolve_layout(user, project)).to eq(default_layout)
    end

    it 'falls back to system default when no configs exist' do
      expect(described_class.resolve_layout(user, project)).to eq(described_class::SYSTEM_DEFAULT_LAYOUT)
    end

    it 'prefers user config over project default' do
      user_layout = [{ 'widgets' => ['recent_tickets'] }]
      default_layout = [{ 'widgets' => ['stats_cards'] }]
      create(:dashboard_configuration, user: user, project: project, organisation: organisation, layout: user_layout)
      create(:dashboard_configuration, :project_default, project: project, organisation: organisation, layout: default_layout)

      expect(described_class.resolve_layout(user, project)).to eq(user_layout)
    end

    it 'falls through to project default when user config has empty layout' do
      default_layout = [{ 'widgets' => ['stats_cards'] }]
      create(:dashboard_configuration, user: user, project: project, organisation: organisation, layout: [])
      create(:dashboard_configuration, :project_default, project: project, organisation: organisation, layout: default_layout)

      expect(described_class.resolve_layout(user, project)).to eq(default_layout)
    end

    it 'falls through to system default when both configs have empty layouts' do
      create(:dashboard_configuration, user: user, project: project, organisation: organisation, layout: [])
      create(:dashboard_configuration, :project_default, project: project, organisation: organisation, layout: [])

      expect(described_class.resolve_layout(user, project)).to eq(described_class::SYSTEM_DEFAULT_LAYOUT)
    end

    it 'falls through to system default when project default has empty layout and no user config' do
      create(:dashboard_configuration, :project_default, project: project, organisation: organisation, layout: [])

      expect(described_class.resolve_layout(user, project)).to eq(described_class::SYSTEM_DEFAULT_LAYOUT)
    end
  end

  describe '.resolve_layout_with_source' do
    let(:user_layout) { [{ 'widgets' => ['recent_tickets'] }] }
    let(:default_layout) { [{ 'widgets' => ['stats_cards'] }] }

    it 'reports owned: true for the user own config' do
      create(:dashboard_configuration, user: user, project: project, organisation: organisation, layout: user_layout)

      result = described_class.resolve_layout_with_source(user, project)
      expect(result.layout).to eq(user_layout)
      expect(result.owned).to be true
    end

    it 'reports owned: false for an inherited project default' do
      create(:dashboard_configuration, :project_default, project: project, organisation: organisation, layout: default_layout)

      result = described_class.resolve_layout_with_source(user, project)
      expect(result.layout).to eq(default_layout)
      expect(result.owned).to be false
    end

    it 'reports owned: false for the system default fallback' do
      result = described_class.resolve_layout_with_source(user, project)
      expect(result.layout).to eq(described_class::SYSTEM_DEFAULT_LAYOUT)
      expect(result.owned).to be false
    end

    it 'treats an empty user layout as no own config (falls through, owned: false)' do
      create(:dashboard_configuration, user: user, project: project, organisation: organisation, layout: [])
      create(:dashboard_configuration, :project_default, project: project, organisation: organisation, layout: default_layout)

      result = described_class.resolve_layout_with_source(user, project)
      expect(result.layout).to eq(default_layout)
      expect(result.owned).to be false
    end
  end

  # D3: a missing component class is swallowed (config drift -> skip), but a bug *inside* a
  # component initializer must crash loudly instead of silently dropping the widget.
  describe '.component_for_widget error policy' do
    it 'propagates an error raised inside a component initializer (not swallowed)' do
      broken = Class.new do
        def initialize(*, **)
          raise NameError, 'uninitialized constant Boom'
        end
      end
      stub_const('Dashboard::BrokenComponent', broken)
      registry = described_class::WIDGET_REGISTRY.merge(
        'broken' => { label_key: 'x', component: 'Dashboard::BrokenComponent', units: 1, permission: nil }
      )
      stub_const('Dashboards::LayoutEngine::WIDGET_REGISTRY', registry)

      expect do
        described_class.component_for_widget({ 'key' => 'broken' }, project: project, user: user)
      end.to raise_error(NameError, /Boom/)
    end
  end

  describe 'item count limit' do
    it 'LIST_LIMIT_OPTIONS is a frozen list of positive integers' do
      expect(described_class::LIST_LIMIT_OPTIONS).to all(be_a(Integer))
      expect(described_class::LIST_LIMIT_OPTIONS).to all(be > 0)
      expect(described_class::LIST_LIMIT_OPTIONS).to be_frozen
    end

    it 'keeps both defaults inside the selectable option set' do
      expect(described_class::LIST_LIMIT_OPTIONS).to include(described_class::DEFAULT_ITEM_LIMIT)
      expect(described_class::LIST_LIMIT_OPTIONS).to include(described_class::GROUPED_TICKETS_LIMIT)
    end

    it 'has an item_count label in DE and EN' do
      %i[de en].each do |locale|
        expect(I18n.exists?('dashboard.configuration.item_count', locale)).to be(true), "missing item_count in #{locale}"
      end
    end

    describe '.sanitized_item_limit' do
      it 'returns a whitelisted integer unchanged' do
        expect(described_class.sanitized_item_limit(15)).to eq(15)
      end

      it 'parses a whitelisted numeric string (form param)' do
        expect(described_class.sanitized_item_limit('20')).to eq(20)
      end

      it 'rejects values outside the whitelist (incl. boundary-adjacent)' do
        expect(described_class.sanitized_item_limit(4)).to be_nil
        expect(described_class.sanitized_item_limit(7)).to be_nil
        expect(described_class.sanitized_item_limit(26)).to be_nil
        expect(described_class.sanitized_item_limit('13')).to be_nil
      end

      it 'rejects nil and non-numeric input' do
        expect(described_class.sanitized_item_limit(nil)).to be_nil
        expect(described_class.sanitized_item_limit('abc')).to be_nil
      end

      # Whitelist positive iteration: EVERY allowed value must be accepted, as Integer AND as the
      # form-param String. A negative-only suite stays green if someone shrinks LIST_LIMIT_OPTIONS
      # (e.g. drops 25) or rewrites the membership check as a narrower range.
      it 'accepts every whitelisted option, as Integer and as String' do
        described_class::LIST_LIMIT_OPTIONS.each do |n|
          expect(described_class.sanitized_item_limit(n)).to eq(n), "Integer #{n} should be accepted"
          expect(described_class.sanitized_item_limit(n.to_s)).to eq(n), "String #{n.inspect} should be accepted"
        end
      end

      it 'rejects a Float and a decimal string even when the integer part is whitelisted' do
        # Integer coercion only runs on Strings; a Float is not an Integer, and Integer('15.5') is nil.
        expect(described_class.sanitized_item_limit(15.0)).to be_nil
        expect(described_class.sanitized_item_limit('15.5')).to be_nil
      end
    end

    describe '.effective_item_limit' do
      it 'uses a stored valid limit' do
        expect(described_class.effective_item_limit('key' => 'recent_notes', 'limit' => 25)).to eq(25)
      end

      it 'falls back to DEFAULT_ITEM_LIMIT when no/invalid limit is stored' do
        expect(described_class.effective_item_limit('key' => 'recent_notes')).to eq(described_class::DEFAULT_ITEM_LIMIT)
        expect(described_class.effective_item_limit('key' => 'recent_notes', 'limit' => 7)).to eq(described_class::DEFAULT_ITEM_LIMIT)
      end

      it 'falls back to the higher grouped default for grouped recent_tickets without a stored limit' do
        expect(described_class.effective_item_limit('key' => 'recent_tickets', 'display' => 'grouped_status'))
          .to eq(described_class::GROUPED_TICKETS_LIMIT)
      end

      it 'lets a stored limit override the grouped default' do
        expect(described_class.effective_item_limit('key' => 'recent_tickets', 'display' => 'grouped_status', 'limit' => 10)).to eq(10)
      end

      it 'falls back to the grouped default (not the flat one) when a grouped widget has an INVALID limit' do
        # Connected default-selection: a bad stored value must fall to the widget's OWN default (20 for
        # grouped), not the flat DEFAULT_ITEM_LIMIT. Kills a fallback that forgets the widget on invalid.
        expect(described_class.effective_item_limit('key' => 'recent_tickets', 'display' => 'grouped_status', 'limit' => 7))
          .to eq(described_class::GROUPED_TICKETS_LIMIT)
      end

      it 'accepts a legacy string widget (no limit) and returns the default' do
        expect(described_class.effective_item_limit('recent_notes')).to eq(described_class::DEFAULT_ITEM_LIMIT)
      end
    end

    # The default (no stored limit) is its own decision point: grouped recent_tickets shows more.
    # Pinned directly so a mutation of the grouped check (start_with?('grouped_') -> == 'grouped_status',
    # or dropping it entirely) breaks here rather than only in the integration.
    describe '.default_item_limit' do
      it 'returns the higher grouped cap for BOTH grouped recent_tickets modes' do
        %w[grouped_status grouped_priority].each do |mode|
          expect(described_class.default_item_limit('key' => 'recent_tickets', 'display' => mode))
            .to eq(described_class::GROUPED_TICKETS_LIMIT), "#{mode} should use the grouped cap"
        end
      end

      it 'returns the flat default for non-grouped recent_tickets and for every other list widget' do
        [nil, 'cards', 'list'].each do |mode|
          expect(described_class.default_item_limit('key' => 'recent_tickets', 'display' => mode))
            .to eq(described_class::DEFAULT_ITEM_LIMIT), "recent_tickets/#{mode.inspect} should use the flat default"
        end
        %w[recent_notes smart_folder_tickets unknown_widget].each do |key|
          expect(described_class.default_item_limit('key' => key)).to eq(described_class::DEFAULT_ITEM_LIMIT)
        end
      end
    end
  end

  # The three list widgets carry :extra_params so the editor renders their settings panel and the
  # parser keeps their fields. A regression dropping :extra_params would silently hide the limit
  # control AND drop the value on save — this pins the contract.
  describe 'list widgets carry settings (extra_params)' do
    it 'defines extra_params for every limit-bearing list widget' do
      %w[recent_tickets recent_notes smart_folder_tickets].each do |key|
        expect(described_class::WIDGET_REGISTRY.dig(key, :extra_params)).to respond_to(:call),
                                                                            "#{key} must keep :extra_params so its item-count setting survives"
      end
    end
  end
end
