# frozen_string_literal: true

require 'rails_helper'

# What:  Organisations::DashboardConfigurationsController#parse_layout_from_params (private).
# Type:  Controller unit spec (drives the private parser via controller.send).
# Why:   The save path turns the nested rows/widgets params into the stored layout. In the
#        auto-columns model a row is just { 'widgets' => [...] } (NO row "type"), widget settings
#        and width come from Dashboards::LayoutEngine.build_widget (width stored only above the
#        minimum), and rows that end up with no widget are dropped.
RSpec.describe Organisations::DashboardConfigurationsController, type: :controller do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let(:membership) { create(:membership, user: user, organisation: organisation, role: role, active: true) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    membership
    create(:project_permission, user: user, project: project,
                                tickets_access: 'read_write', notes_access: 'read_write',
                                documents_access: 'read_write')
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  describe '#parse_layout_from_params (private)' do
    def parse_with(rows_hash)
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new(rows: rows_hash))
      controller.send(:parse_layout_from_params)
    end

    it 'parses a row with one widget into { widgets: [...] } with no row type' do
      result = parse_with({ '0' => { widgets: { '0' => { key: 'stats_cards' } } } })
      expect(result).to eq([{ 'widgets' => [{ 'key' => 'stats_cards' }] }])
    end

    it 'parses recent_tickets with display and period' do
      result = parse_with({ '0' => { widgets: { '0' => { key: 'recent_tickets', display: 'list', period: 'this_week' } } } })
      expect(result.first['widgets'].first).to eq({ 'key' => 'recent_tickets', 'display' => 'list', 'period' => 'this_week' })
    end

    it 'parses smart_folder_tickets with folder_id' do
      result = parse_with({ '0' => { widgets: { '0' => { key: 'smart_folder_tickets', folder_id: 'abc-123' } } } })
      expect(result.first['widgets'].first).to eq({ 'key' => 'smart_folder_tickets', 'folder_id' => 'abc-123' })
    end

    it 'parses stats_cards with card_keys and card_settings' do
      result = parse_with({
                            '0' => { widgets: { '0' => {
                              key: 'stats_cards',
                              card_keys: %w[tickets open_hours],
                              card_settings: {
                                'tickets' => { period: 'this_month' },
                                'open_hours' => { period: 'this_week', scope: 'mine' }
                              }
                            } } }
                          })

      expect(result.first['widgets'].first['cards']).to eq([
                                                             { 'key' => 'tickets', 'period' => 'this_month' },
                                                             { 'key' => 'open_hours', 'period' => 'this_week', 'scope' => 'mine' }
                                                           ])
    end

    # parse_card_settings edge branches — each shapes the saved cards JSONB and would silently
    # corrupt/lose a setting if it regressed, but is only reachable through this parser.
    it 'rejects a blank card_key (no phantom card lands in the saved layout)' do
      result = parse_with({ '0' => { widgets: { '0' => { key: 'stats_cards', card_keys: ['tickets', ''] } } } })
      expect(result.first['widgets'].first['cards']).to eq([{ 'key' => 'tickets' }])
    end

    it 'stores a card with no card_settings entry as key-only (no period/scope keys)' do
      result = parse_with({ '0' => { widgets: { '0' => { key: 'stats_cards', card_keys: ['tickets'] } } } })
      expect(result.first['widgets'].first['cards']).to eq([{ 'key' => 'tickets' }])
    end

    it 'drops a blank card period instead of storing an empty string' do
      result = parse_with({
                            '0' => { widgets: { '0' => {
                              key: 'stats_cards', card_keys: ['tickets'], card_settings: { 'tickets' => { period: '' } }
                            } } }
                          })
      expect(result.first['widgets'].first['cards']).to eq([{ 'key' => 'tickets' }])
    end

    it 'drops blank widget keys entirely (no nil entry survives in the widgets array)' do
      result = parse_with({ '0' => { widgets: { '0' => { key: 'recent_tickets' }, '1' => { key: '' } } } })
      expect(result.first['widgets']).to eq([{ 'key' => 'recent_tickets' }])
    end

    it 'persists a width above the minimum but drops a width equal to the minimum' do
      # recent_tickets has a 2-unit minimum: 2 is the default (storing it would be noise), 4 is kept.
      at_min = parse_with({ '0' => { widgets: { '0' => { key: 'recent_tickets', units: '2' } } } })
      expect(at_min.first['widgets'].first).not_to have_key('units')

      wider = parse_with({ '0' => { widgets: { '0' => { key: 'recent_tickets', units: '4' } } } })
      expect(wider.first['widgets'].first['units']).to eq(4)
    end

    it 'persists a whitelisted item limit for the list widgets' do
      %w[recent_tickets recent_notes].each do |key|
        result = parse_with({ '0' => { widgets: { '0' => { key: key, limit: '15' } } } })
        expect(result.first['widgets'].first['limit']).to eq(15)
      end

      sf = parse_with({ '0' => { widgets: { '0' => { key: 'smart_folder_tickets', folder_id: 'abc', limit: '10' } } } })
      expect(sf.first['widgets'].first['limit']).to eq(10)
    end

    it 'drops an out-of-whitelist item limit (a forged value never lands in the layout)' do
      # kills a mutation that drops the LIST_LIMIT_OPTIONS whitelist in assign_item_limit
      result = parse_with({ '0' => { widgets: { '0' => { key: 'recent_tickets', limit: '7' } } } })
      expect(result.first['widgets'].first).not_to have_key('limit')
    end

    it 'leaves the limit absent when no limit param is sent (component default applies)' do
      result = parse_with({ '0' => { widgets: { '0' => { key: 'recent_notes' } } } })
      expect(result.first['widgets'].first).not_to have_key('limit')
    end

    it 'never attaches a limit to a non-list widget (only the three list branches parse it)' do
      result = parse_with({ '0' => { widgets: { '0' => { key: 'stats_cards', limit: '10' } } } })
      expect(result.first['widgets'].first).not_to have_key('limit')
    end

    it 'persists every whitelisted option (positive iteration over the constant)' do
      Dashboards::LayoutEngine::LIST_LIMIT_OPTIONS.each do |n|
        result = parse_with({ '0' => { widgets: { '0' => { key: 'recent_tickets', limit: n.to_s } } } })
        expect(result.first['widgets'].first['limit']).to eq(n), "limit #{n} should be stored"
      end
    end

    it 'stores the boundary options 5 and 25 but drops 4 and 26' do
      { '5' => 5, '25' => 25 }.each do |sent, stored|
        result = parse_with({ '0' => { widgets: { '0' => { key: 'recent_tickets', limit: sent } } } })
        expect(result.first['widgets'].first['limit']).to eq(stored)
      end
      %w[4 26].each do |sent|
        result = parse_with({ '0' => { widgets: { '0' => { key: 'recent_tickets', limit: sent } } } })
        expect(result.first['widgets'].first).not_to have_key('limit'), "out-of-range #{sent} should be dropped"
      end
    end

    # A limit equal to the default (5) is stored authoritatively, NOT skipped as "noise" (unlike width).
    # This is the decision that lets a user pin 5 on a grouped recent_tickets whose unset fallback is 20.
    # Kills a mutation adding `&& limit != DEFAULT_ITEM_LIMIT` to assign_item_limit.
    it 'stores a valid limit even when it equals the default (5)' do
      result = parse_with({ '0' => { widgets: { '0' => { key: 'recent_tickets', display: 'grouped_status', limit: '5' } } } })
      expect(result.first['widgets'].first['limit']).to eq(5)
    end

    it 'parses multiple rows, each as { widgets: [...] }' do
      result = parse_with({
                            '0' => { widgets: { '0' => { key: 'stats_cards' } } },
                            '1' => { widgets: { '0' => { key: 'recent_tickets' }, '1' => { key: 'recent_notes' } } }
                          })

      expect(result.length).to eq(2)
      expect(result[0]).to eq({ 'widgets' => [{ 'key' => 'stats_cards' }] })
      expect(result[1]['widgets'].length).to eq(2)
    end

    it 'drops a row that ends up with no widgets (all entries blank)' do
      result = parse_with({
                            '0' => { widgets: { '0' => { key: 'stats_cards' } } },
                            '1' => { widgets: { '0' => { key: '' } } }
                          })
      expect(result).to eq([{ 'widgets' => [{ 'key' => 'stats_cards' }] }])
    end

    it 'returns an empty array when there is no rows param' do
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new({}))
      expect(controller.send(:parse_layout_from_params)).to eq([])
    end
  end
end
