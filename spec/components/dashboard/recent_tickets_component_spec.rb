# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Dashboard::RecentTicketsComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:policy) { instance_double(ProjectPolicy) }

  before do
    allow(ProjectPolicy).to receive(:new).with(user, project).and_return(policy)
    allow(policy).to receive(:area_access?).with(:tickets, :read).and_return(true)
    allow(policy).to receive(:area_access?).with(:tickets, :write).and_return(false)
  end

  describe '#should_render?' do
    it 'returns true when user has ticket read access' do
      component = described_class.new(project: project, user: user)
      expect(component.should_render?).to be true
    end

    it 'returns false when user lacks ticket read access' do
      allow(policy).to receive(:area_access?).with(:tickets, :read).and_return(false)
      component = described_class.new(project: project, user: user)
      expect(component.should_render?).to be false
    end
  end

  describe 'display modes' do
    it 'defaults to cards display' do
      component = described_class.new(project: project, user: user)
      expect(component.send(:display)).to eq('cards')
    end

    it 'accepts valid display modes' do
      %w[cards list grouped_status grouped_priority].each do |mode|
        component = described_class.new(project: project, user: user, display: mode)
        expect(component.send(:display)).to eq(mode)
      end
    end

    it 'falls back to cards for invalid display mode' do
      component = described_class.new(project: project, user: user, display: 'invalid')
      expect(component.send(:display)).to eq('cards')
    end
  end

  describe 'period' do
    it 'defaults to all_time' do
      component = described_class.new(project: project, user: user)
      expect(component.send(:period)).to eq('all_time')
    end

    it 'accepts custom period' do
      component = described_class.new(project: project, user: user, period: 'this_month')
      expect(component.send(:period)).to eq('this_month')
    end
  end

  # Configurable item count (one shared limit across all display modes). Tested on the private
  # reader so the assertion never touches the render path (route-helper proxy is order-fragile).
  describe '#item_limit' do
    it 'defaults to 5 in a non-grouped display' do
      component = described_class.new(project: project, user: user, display: 'cards')
      expect(component.send(:item_limit)).to eq(5)
    end

    it 'defaults to 20 in a grouped display (preserves the legacy higher cap)' do
      component = described_class.new(project: project, user: user, display: 'grouped_status')
      expect(component.send(:item_limit)).to eq(20)
    end

    it 'uses a stored valid limit across every display mode' do
      %w[cards list grouped_status grouped_priority].each do |mode|
        component = described_class.new(project: project, user: user, display: mode, limit: 15)
        expect(component.send(:item_limit)).to eq(15)
      end
    end

    it 'ignores an out-of-whitelist limit and falls back to the default' do
      component = described_class.new(project: project, user: user, display: 'cards', limit: 7)
      expect(component.send(:item_limit)).to eq(5)
    end

    it 'lets an explicit limit override the higher grouped default (stored 5 on a grouped widget)' do
      component = described_class.new(project: project, user: user, display: 'grouped_status', limit: 5)
      expect(component.send(:item_limit)).to eq(5)
    end
  end

  # Connected block: the reader is one thing, but the QUERY must actually apply it. Reverting
  # `.limit(item_limit)` to `.limit(5)` or `.limit(grouped? ? 20 : 5)` passes every #item_limit test
  # above yet fails here. Uses the private relation so no route helpers are touched.
  describe '#recent_tickets honours the limit in the query' do
    before do
      12.times { |i| create(:ticket, project: project, organisation: organisation, updated_at: i.minutes.ago) }
    end

    it 'returns DEFAULT_ITEM_LIMIT (5) rows when no limit is configured' do
      component = described_class.new(project: project, user: user, display: 'cards')
      expect(component.send(:recent_tickets).to_a.size).to eq(5)
    end

    it 'returns exactly the configured number of rows' do
      component = described_class.new(project: project, user: user, display: 'cards', limit: 10)
      expect(component.send(:recent_tickets).to_a.size).to eq(10)
    end
  end

  describe '#period_label' do
    it 'returns nil for all_time' do
      component = described_class.new(project: project, user: user, period: 'all_time')
      expect(component.send(:period_label)).to be_nil
    end

    it 'returns translated label for a specific period' do
      component = described_class.new(project: project, user: user, period: 'this_month')
      label = component.send(:period_label)
      expect(label).to be_present
    end
  end

  describe 'color methods' do
    let(:component) { described_class.new(project: project, user: user) }

    it 'delegates status_dot_color to TicketColorMap' do
      expect(component.send(:status_dot_color, 'open')).to eq(TicketColorMap.status_dot_color('open'))
    end

    it 'delegates priority_dot_color to TicketColorMap' do
      expect(component.send(:priority_dot_color, 'high')).to eq(TicketColorMap.priority_dot_color('high'))
    end

    it 'returns status color for grouped_status' do
      component = described_class.new(project: project, user: user, display: 'grouped_status')
      expect(component.send(:group_dot_color, 'open')).to eq(TicketColorMap.status_dot_color('open'))
    end

    it 'returns priority color for grouped_priority' do
      component = described_class.new(project: project, user: user, display: 'grouped_priority')
      expect(component.send(:group_dot_color, 'high')).to eq(TicketColorMap.priority_dot_color('high'))
    end
  end

  describe '#grouped?' do
    it 'returns true for grouped_status' do
      component = described_class.new(project: project, user: user, display: 'grouped_status')
      expect(component.send(:grouped?)).to be true
    end

    it 'returns true for grouped_priority' do
      component = described_class.new(project: project, user: user, display: 'grouped_priority')
      expect(component.send(:grouped?)).to be true
    end

    it 'returns false for cards' do
      component = described_class.new(project: project, user: user, display: 'cards')
      expect(component.send(:grouped?)).to be false
    end

    it 'returns false for list' do
      component = described_class.new(project: project, user: user, display: 'list')
      expect(component.send(:grouped?)).to be false
    end
  end

  describe 'rendering' do
    before do
      create(:ticket, project: project, organisation: organisation, title: 'Test Ticket', updated_at: 1.hour.ago)

      # Route helpers aren't fully available in component tests -
      # stub the helper method used in the template
      allow_any_instance_of(TicketsHelper).to receive(:ticket_turbo_frame_path).and_return('#')
    end

    it 'renders in cards mode' do
      component = described_class.new(project: project, user: user, display: 'cards')
      render_inline(component)
      expect(page).to have_content('Test Ticket')
    end

    it 'renders in list mode' do
      component = described_class.new(project: project, user: user, display: 'list')
      render_inline(component)
      expect(page).to have_content('Test Ticket')
    end
  end

  # The widget shows active work, not the backlog. Asserted on the private relation
  # so no route helpers are touched.
  describe '#recent_tickets excludes backlog (active_work)' do
    before do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                           options: { 'allowed_values' => [
                                             { 'value' => 'Backlog', 'labels' => { 'de' => 'Backlog' }, 'system_functions' => ['is_backlog'] },
                                             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] }
                                           ] })
    end

    it 'omits tickets parked in a backlog status' do
      active = create(:ticket, project: project, organisation: organisation, custom_attributes: { 'status' => 'Neu' })
      create(:ticket, project: project, organisation: organisation, custom_attributes: { 'status' => 'Backlog' })

      result = described_class.new(project: project, user: user).send(:recent_tickets).to_a
      expect(result).to contain_exactly(active)
    end

    it 'still shows an untriaged (nil-status) ticket' do
      untriaged = create(:ticket, project: project, organisation: organisation, custom_attributes: {})
      create(:ticket, project: project, organisation: organisation, custom_attributes: { 'status' => 'Backlog' })

      result = described_class.new(project: project, user: user).send(:recent_tickets).to_a
      expect(result).to contain_exactly(untriaged)
    end
  end

  describe '#recent_tickets without a backlog status configured' do
    it 'shows all tickets (active_work is a no-op when no backlog values exist)' do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                           options: { 'allowed_values' => [
                                             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] }
                                           ] })
      a = create(:ticket, project: project, organisation: organisation, custom_attributes: { 'status' => 'Neu' })
      b = create(:ticket, project: project, organisation: organisation, custom_attributes: {})

      result = described_class.new(project: project, user: user).send(:recent_tickets).to_a
      expect(result).to contain_exactly(a, b)
    end
  end

  # In-widget search: same engine (TicketSearchQuery) as the tickets list page, but deliberately over
  # ALL of the project's tickets — past the active_work/period narrowing the default view applies.
  # Asserted on the private relation/predicates so no route helpers are touched.
  describe 'in-widget search' do
    before do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                           options: { 'allowed_values' => [
                                             { 'value' => 'Backlog', 'labels' => { 'de' => 'Backlog' }, 'system_functions' => ['is_backlog'] },
                                             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] }
                                           ] })
    end

    it 'reports searching? only when a non-blank query is given' do
      expect(described_class.new(project: project, user: user).send(:searching?)).to be false
      expect(described_class.new(project: project, user: user, search_query: '   ').send(:searching?)).to be false
      expect(described_class.new(project: project, user: user, search_query: 'Quokka').send(:searching?)).to be true
    end

    it 'finds matches across ALL tickets — including backlog the default view hides' do
      hit = create(:ticket, project: project, organisation: organisation, title: 'Quokka im Backlog',
                            custom_attributes: { 'status' => 'Backlog' })
      create(:ticket, project: project, organisation: organisation, title: 'Wombat aktiv',
                      custom_attributes: { 'status' => 'Neu' })

      component = described_class.new(project: project, user: user, search_query: 'Quokka')
      expect(component.send(:recent_tickets).map(&:id)).to contain_exactly(hit.id)
    end

    it 'reverts to the default active-work view when the query is blank (whitespace only)' do
      create(:ticket, project: project, organisation: organisation, title: 'Quokka im Backlog',
                      custom_attributes: { 'status' => 'Backlog' })
      active = create(:ticket, project: project, organisation: organisation, title: 'Wombat aktiv',
                               custom_attributes: { 'status' => 'Neu' })

      component = described_class.new(project: project, user: user, search_query: '   ')
      expect(component.send(:recent_tickets).to_a.map(&:id)).to contain_exactly(active.id)
    end

    it 'caps the widget at the configured limit but reports the full match total' do
      # Bulk fixture creation: each ticket validates its custom attributes (one definition lookup),
      # which Prosopite reads as an N+1. Not under test here.
      Prosopite.pause
      7.times { |i| create(:ticket, project: project, organisation: organisation, title: "Quokka #{i}", custom_attributes: { 'status' => 'Neu' }) }
      Prosopite.resume

      component = described_class.new(project: project, user: user, display: 'cards', limit: 5, search_query: 'Quokka')
      expect(component.send(:recent_tickets).size).to eq(5)
      expect(component.send(:search_total)).to eq(7)
      expect(component.send(:more_results?)).to be true
    end

    it 'does not offer "more results" when every match already fits' do
      Prosopite.pause
      3.times { |i| create(:ticket, project: project, organisation: organisation, title: "Quokka #{i}", custom_attributes: { 'status' => 'Neu' }) }
      Prosopite.resume

      component = described_class.new(project: project, user: user, display: 'cards', limit: 5, search_query: 'Quokka')
      expect(component.send(:more_results?)).to be false
    end

    it 'derives a deterministic, project-scoped frame id' do
      component = described_class.new(project: project, user: user)
      expect(component.send(:frame_id)).to eq("recent_tickets_widget_#{project.id}")
    end
  end
end
