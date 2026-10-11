# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Dashboard::StatsCardsComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:policy) { instance_double(ProjectPolicy) }

  let(:role) { create(:role, organisation: organisation) }

  # Tenant must be set before all tenant-scoped factory calls
  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    allow(ProjectPolicy).to receive(:new).with(user, project).and_return(policy)
    allow(policy).to receive(:area_access?).and_return(true)
    # TimeSessionPolicy::Scope returns the relation unchanged
    allow(TimeSessionPolicy::Scope).to receive(:new) { |_user, scope| double(resolve: scope) }
  end

  after { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation) }

  describe '#should_render?' do
    it 'returns true when visible cards exist' do
      component = described_class.new(project: project, user: user)
      expect(component.should_render?).to be true
    end

    it 'returns false when all cards are permission-gated and user has no access' do
      allow(policy).to receive(:area_access?).and_return(false)
      component = described_class.new(project: project, user: user,
                                      card_settings: [{ 'key' => 'tickets' }])
      expect(component.should_render?).to be false
    end
  end

  describe '#visible_cards' do
    it 'filters out cards the user has no permission for' do
      allow(policy).to receive(:area_access?).with(:tickets, :read).and_return(false)
      allow(policy).to receive(:area_access?).with(:notes, :read).and_return(true)

      component = described_class.new(project: project, user: user,
                                      card_settings: [{ 'key' => 'tickets' }, { 'key' => 'notes' }])
      keys = component.visible_cards.map { |c| c[:key] }
      expect(keys).to eq(['notes'])
    end

    it 'skips unknown card keys' do
      component = described_class.new(project: project, user: user,
                                      card_settings: [{ 'key' => 'nonexistent' }])
      expect(component.visible_cards).to be_empty
    end

    it 'uses default cards when no settings given' do
      component = described_class.new(project: project, user: user)
      keys = component.visible_cards.map { |c| c[:key] }
      expect(keys).to eq(%w[tickets notes open_hours documents])
    end

    it 'passes period from settings to compute method' do
      component = described_class.new(project: project, user: user,
                                      card_settings: [{ 'key' => 'tickets', 'period' => 'today' }])
      card = component.visible_cards.first
      expect(card[:key]).to eq('tickets')
      expect(card[:data][:value]).to be_a(Integer)
    end
  end

  # The card grid is now pure CSS (auto-fit), not a Ruby method: the columns reflow to the widget's
  # own width so the same widget works at any dashboard span. Pin that the auto-fit track ships.
  describe 'card grid' do
    it 'renders an auto-fit grid track that reflows to the container width' do
      html = render_inline(described_class.new(project: project, user: user)).to_html
      expect(html).to include('grid-cols-[repeat(auto-fit,minmax(9rem,1fr))]')
    end
  end

  describe 'compute methods' do
    describe '#compute_tickets' do
      it 'counts tickets and done tickets' do
        create(:ticket, project: project, organisation: organisation,
                        custom_attributes: { 'status' => 'open' })
        create(:ticket, project: project, organisation: organisation,
                        custom_attributes: { 'status' => 'done' })

        component = described_class.new(project: project, user: user,
                                        card_settings: [{ 'key' => 'tickets' }])
        card = component.visible_cards.first
        expect(card[:data][:value]).to eq(2)
      end
    end

    describe '#compute_notes' do
      it 'counts notes' do
        create(:note, project: project, organisation: organisation, creator: user)

        component = described_class.new(project: project, user: user,
                                        card_settings: [{ 'key' => 'notes' }])
        card = component.visible_cards.first
        expect(card[:data][:value]).to eq(1)
      end
    end

    describe '#compute_documents' do
      it 'counts documents' do
        create(:document, project: project, organisation: organisation, creator: user)

        component = described_class.new(project: project, user: user,
                                        card_settings: [{ 'key' => 'documents' }])
        card = component.visible_cards.first
        expect(card[:data][:value]).to eq(1)
      end
    end

    describe '#compute_open_tickets' do
      it 'counts active tickets, excluding done via status System Functions' do
        # "done" is excluded because its option carries is_completed — NOT because of a
        # hardcoded 'done' string (that never matched the seeded values; the old bug).
        create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                             options: { 'allowed_values' => [
                                               { 'value' => 'open', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] },
                                               { 'value' => 'done', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
                                             ] })
        create(:ticket, project: project, organisation: organisation,
                        custom_attributes: { 'status' => 'open' })
        create(:ticket, project: project, organisation: organisation,
                        custom_attributes: { 'status' => 'done' })

        component = described_class.new(project: project, user: user,
                                        card_settings: [{ 'key' => 'open_tickets' }])
        card = component.visible_cards.first
        expect(card[:data][:value]).to eq(1)
      end

      it 'counts high priority tickets in subtitle' do
        create(:ticket, project: project, organisation: organisation,
                        custom_attributes: { 'status' => 'open', 'priority' => 'high' })
        create(:ticket, project: project, organisation: organisation,
                        custom_attributes: { 'status' => 'open', 'priority' => 'low' })

        component = described_class.new(project: project, user: user,
                                        card_settings: [{ 'key' => 'open_tickets' }])
        card = component.visible_cards.first
        expect(card[:data][:subtitle]).to include('1')
      end
    end

    describe '#compute_notifications' do
      it 'counts unread in-app notifications' do
        component = described_class.new(project: project, user: user,
                                        card_settings: [{ 'key' => 'notifications' }])
        card = component.visible_cards.first
        expect(card[:data][:value]).to eq(0)
      end
    end

    describe '#compute_open_hours' do
      it 'returns hours value' do
        create(:time_session, project: project, organisation: organisation,
                              creator: user, duration: 120, billed: false)

        component = described_class.new(project: project, user: user,
                                        card_settings: [{ 'key' => 'open_hours' }])
        card = component.visible_cards.first
        expect(card[:data][:value]).to eq('2.0h')
      end

      it 'filters to own sessions with scope mine' do
        other_user = create(:user)
        create(:membership, user: other_user, organisation: organisation, role: role, active: true)
        create(:time_session, project: project, organisation: organisation,
                              creator: other_user, duration: 60, billed: false)
        create(:time_session, project: project, organisation: organisation,
                              creator: user, duration: 30, billed: false)

        component = described_class.new(project: project, user: user,
                                        card_settings: [{ 'key' => 'open_hours', 'scope' => 'mine' }])
        card = component.visible_cards.first
        expect(card[:data][:value]).to eq('0.5h')
      end
    end

    describe '#compute_my_hours' do
      it 'returns hours for current user' do
        create(:time_session, project: project, organisation: organisation,
                              creator: user, duration: 90)

        component = described_class.new(project: project, user: user,
                                        card_settings: [{ 'key' => 'my_hours' }])
        card = component.visible_cards.first
        expect(card[:data][:value]).to eq('1.5h')
      end
    end

    describe '#compute_billed_time' do
      it 'counts billed sessions' do
        create(:time_session, project: project, organisation: organisation,
                              creator: user, duration: 180, billed: true)

        component = described_class.new(project: project, user: user,
                                        card_settings: [{ 'key' => 'billed_time' }])
        card = component.visible_cards.first
        expect(card[:data][:value]).to eq('3.0h')
        expect(card[:data][:subtitle]).to include('1')
      end
    end

    describe '#compute_activities' do
      it 'returns activity count' do
        component = described_class.new(project: project, user: user,
                                        card_settings: [{ 'key' => 'activities' }])
        card = component.visible_cards.first
        expect(card[:data][:value]).to eq(0)
      end
    end
  end

  # "Active work" semantics: backlog (is_backlog) and done (is_completed/is_closed) must
  # not count as open. The 'tickets' total still includes everything.
  describe 'active-work semantics' do
    let(:component) { described_class.new(project: project, user: user) }

    before do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                           options: { 'allowed_values' => [
                                             { 'value' => 'Backlog', 'labels' => { 'de' => 'Backlog' }, 'system_functions' => ['is_backlog'] },
                                             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] },
                                             { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] },
                                             { 'value' => 'Geschlossen', 'labels' => { 'de' => 'Geschlossen' }, 'system_functions' => ['is_closed'] }
                                           ] })
    end

    def ticket_with(status, assignee: nil)
      t = create(:ticket, project: project, organisation: organisation, custom_attributes: { 'status' => status })
      t.ticket_assignments.create!(user: assignee) if assignee
      t
    end

    it 'open_tickets counts only active work (excludes done AND backlog)' do
      ticket_with('Neu')
      ticket_with('Backlog')
      ticket_with('Erledigt')
      ticket_with('Geschlossen')

      expect(component.send(:compute_open_tickets)[:value]).to eq(1)
    end

    it 'open_tickets keeps an untriaged (nil-status) ticket as open' do
      ticket_with('Neu')
      create(:ticket, project: project, organisation: organisation, custom_attributes: {})

      expect(component.send(:compute_open_tickets)[:value]).to eq(2)
    end

    it 'tickets total includes backlog and done' do
      ticket_with('Neu')
      ticket_with('Backlog')
      ticket_with('Erledigt')

      expect(component.send(:compute_tickets)[:value]).to eq(3)
    end

    it 'tickets subtitle counts done (completed/closed) via system functions' do
      ticket_with('Neu')
      ticket_with('Erledigt')
      ticket_with('Geschlossen')

      # .to_i parses the leading integer exactly (start_with('2 ') would also accept odd
      # spacing); pins the done count to 2.
      expect(component.send(:compute_tickets)[:subtitle].to_i).to eq(2)
    end

    it 'tickets subtitle is 0 done when no completed/closed status is configured' do
      project.ticket_attribute_definitions.find_by(name: 'status')
             .update!(options: { 'allowed_values' => [
                        { 'value' => 'Backlog', 'labels' => { 'de' => 'Backlog' }, 'system_functions' => ['is_backlog'] },
                        { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] }
                      ] })
      ticket_with('Neu')
      ticket_with('Backlog')

      # Exercises the empty-closed-values branch (with_status_values([]) => none => 0),
      # the exact surface where the old hardcoded-'done' bug lived.
      expect(component.send(:compute_tickets)[:subtitle].to_i).to eq(0)
    end

    it 'my_tickets totals all mine but counts only my active ones as open' do
      ticket_with('Neu', assignee: user)
      ticket_with('Backlog', assignee: user)
      ticket_with('Erledigt', assignee: user)
      ticket_with('Neu') # unassigned — not mine

      result = component.send(:compute_my_tickets)
      expect(result[:value]).to eq(3)
      expect(result[:subtitle].to_i).to eq(1)
    end
  end
end
