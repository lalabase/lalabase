# frozen_string_literal: true

require 'rails_helper'

RSpec.describe KanbanBoardPresenter do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  let(:kanban_attribute) do
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                         options: {
                                           'allowed_values' => [
                                             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] },
                                             { 'value' => 'In Bearbeitung', 'labels' => { 'de' => 'In Bearbeitung' }, 'system_functions' => ['is_in_progress'] },
                                             { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
                                           ]
                                         })
  end

  let(:tickets_scope) { project.tickets }

  subject(:presenter) { described_class.new(tickets_scope, kanban_attribute) }

  describe '#columns' do
    context 'with tickets in various states' do
      before do
        Prosopite.pause
        create(:ticket, project: project, title: 'Ticket 1', custom_attributes: { 'status' => 'Neu' })
        create(:ticket, project: project, title: 'Ticket 2', custom_attributes: { 'status' => 'Neu' })
        create(:ticket, project: project, title: 'Ticket 3', custom_attributes: { 'status' => 'In Bearbeitung' })
        Prosopite.resume
      end

      it 'groups tickets by attribute value' do
        columns = presenter.columns
        neu_col = columns.find { |c| c[:value] == 'Neu' }
        wip_col = columns.find { |c| c[:value] == 'In Bearbeitung' }

        expect(neu_col[:tickets].size).to eq(2)
        expect(wip_col[:tickets].size).to eq(1)
      end

      it 'includes empty columns for all allowed values' do
        columns = presenter.columns
        erledigt_col = columns.find { |c| c[:value] == 'Erledigt' }

        expect(erledigt_col[:tickets]).to be_empty
        expect(erledigt_col[:total_count]).to eq(0)
      end

      it 'preserves order from allowed_values, behind the unassigned column that always stands (D6)' do
        columns = presenter.columns
        values = columns.map { |c| c[:value] }

        expect(values).to eq([nil, 'Neu', 'In Bearbeitung', 'Erledigt'])
      end
    end

    context 'with unassigned tickets' do
      before do
        Prosopite.pause
        create(:ticket, project: project, title: 'Ohne Status', custom_attributes: {})
        create(:ticket, project: project, title: 'Mit Status', custom_attributes: { 'status' => 'Neu' })
        Prosopite.resume
      end

      it 'creates unassigned column at the beginning' do
        columns = presenter.columns
        expect(columns.first[:value]).to be_nil
        expect(columns.first[:label]).to include('zugeordnet')
        expect(columns.first[:tickets].size).to eq(1)
      end
    end

    context 'with more tickets than TICKETS_PER_COLUMN' do
      before do
        Prosopite.pause
        (described_class::TICKETS_PER_COLUMN + 5).times do |i|
          create(:ticket, project: project, title: "Ticket #{i}", custom_attributes: { 'status' => 'Neu' })
        end
        Prosopite.resume
      end

      it 'limits tickets per column' do
        columns = presenter.columns
        neu_col = columns.find { |c| c[:value] == 'Neu' }

        expect(neu_col[:tickets].size).to eq(described_class::TICKETS_PER_COLUMN)
        expect(neu_col[:has_more]).to be true
        expect(neu_col[:total_count]).to eq(described_class::TICKETS_PER_COLUMN + 5)
      end
    end
  end

  # "Nicht zugeordnet" is a state too (rule 4, D6 of doc/kanban_ticket_als_bahn_plan.md):
  # the column stands even empty, so a card can always be dragged there to
  # clear its value. Strictly required (required, no required_if) gets no EMPTY
  # column; what it holds anyway shows. The flag alone would be a misleading
  # test: it is also set on conditional requirements.
  describe 'the unassigned column (D6)' do
    def with_rules(rules)
      kanban_attribute.update!(validation_rules: rules)
      described_class.new(tickets_scope, kanban_attribute.reload)
    end

    it 'stands empty at 0 unassigned tickets, first, and holds the card at 1' do
      create(:ticket, project: project, custom_attributes: { 'status' => 'Neu' })
      column = presenter.columns.first
      expect(column[:value]).to be_nil
      expect(column[:tickets]).to be_empty
      expect(column[:hidden_count]).to eq(0)

      create(:ticket, project: project, title: 'Ohne', custom_attributes: {})
      column = described_class.new(tickets_scope, kanban_attribute).columns.first
      expect(column[:value]).to be_nil
      expect(column[:tickets].map(&:title)).to eq(['Ohne'])
    end

    it 'is left out for a strictly required attribute only while it would be empty' do
      create(:ticket, project: project, custom_attributes: { 'status' => 'Neu' })
      expect(with_rules('required' => true).columns.map { |c| c[:value] }).to eq(['Neu', 'In Bearbeitung', 'Erledigt'])

      create(:ticket, project: project, title: 'Altlast', custom_attributes: {})
      columns = with_rules('required' => true).columns
      expect(columns.first[:value]).to be_nil
      expect(columns.first[:tickets].map(&:title)).to eq(['Altlast'])
    end

    it 'stands for a conditional requirement, which carries the required flag too' do
      create(:ticket, project: project, custom_attributes: { 'status' => 'Neu' })
      columns = with_rules('required' => true, 'required_if' => { 'attribute' => 'kind', 'value' => 'bug' }).columns
      expect(columns.first[:value]).to be_nil
      expect(columns.first[:tickets]).to be_empty
    end

    it 'shows the open unassigned ticket loaded from beyond the cap even when strictly required' do
      stub_const('KanbanBoardPresenter::MAX_TOTAL_TICKETS', 2)
      Prosopite.pause
      2.times { |i| create(:ticket, project: project, title: "Aktiv #{i}", custom_attributes: { 'status' => 'Neu' }) }
      open = create(:ticket, project: project, title: 'Offen ohne Wert', custom_attributes: {})
      Prosopite.resume
      kanban_attribute.update!(validation_rules: { 'required' => true })

      columns = described_class.new(project.tickets.order(:number), kanban_attribute.reload, selected: open).columns
      expect(columns.first[:value]).to be_nil
      expect(columns.first[:tickets].map(&:title)).to eq(['Offen ohne Wert'])
      expect(columns.first[:total_count]).to eq(1)
      expect(columns.first[:hidden_count]).to eq(0)
    end
  end

  # The open ticket gets its card across both caps, from the filtered scope
  # (D3): appended last, never twice; hidden_count counts what is NOT rendered,
  # so the "+n weitere" note stays right with the appended card.
  describe 'the card of the open ticket (D3)' do
    def neu_tickets(count)
      Prosopite.pause
      created = count.times.map { |i| create(:ticket, project: project, title: "Karte #{i + 1}", custom_attributes: { 'status' => 'Neu' }) }
      Prosopite.resume
      created
    end

    def neu_column(selected:, scope: project.tickets.order(:number))
      described_class.new(scope, kanban_attribute, selected: selected).columns.find { |c| c[:value] == 'Neu' }
    end

    it 'renders the 21st card when it is the open one: 21 rendered, nothing hidden, no note' do
      tickets = neu_tickets(21)
      column = neu_column(selected: tickets.last)
      expect(column[:tickets].size).to eq(21)
      expect(column[:tickets].last).to eq(tickets.last)
      expect(column[:tickets].uniq.size).to eq(21)
      expect(column[:hidden_count]).to eq(0)
      expect(column[:has_more]).to be false
    end

    it 'keeps the note right around the column cap: 19 and 20 with the last open, 21 with the 20th open' do
      tickets = neu_tickets(21)
      column = neu_column(selected: tickets[19])
      expect(column[:tickets].size).to eq(20)
      expect(column[:hidden_count]).to eq(1)
      expect(column[:has_more]).to be true

      scope = project.tickets.order(:number).where(id: tickets.first(20).map(&:id))
      column = neu_column(selected: tickets[19], scope: scope)
      expect(column[:tickets].size).to eq(20)
      expect(column[:hidden_count]).to eq(0)

      scope = project.tickets.order(:number).where(id: tickets.first(19).map(&:id))
      column = neu_column(selected: tickets[18], scope: scope)
      expect(column[:tickets].size).to eq(19)
      expect(column[:hidden_count]).to eq(0)
    end

    it 'loads the open ticket from beyond the total cap into its column, counting it once' do
      stub_const('KanbanBoardPresenter::MAX_TOTAL_TICKETS', 5)
      tickets = neu_tickets(6)
      presenter = described_class.new(project.tickets.order(:number), kanban_attribute, selected: tickets.last)
      column = presenter.columns.find { |c| c[:value] == 'Neu' }
      expect(presenter.capped?).to be true
      expect(column[:tickets].size).to eq(6)
      expect(column[:tickets].last).to eq(tickets.last)
      expect(column[:total_count]).to eq(6)
      expect(column[:hidden_count]).to eq(0)

      presenter = described_class.new(project.tickets.order(:number).limit(5), kanban_attribute, selected: nil)
      expect(presenter.columns.find { |c| c[:value] == 'Neu' }[:tickets].size).to eq(5)
    end

    it 'gives a ticket the scope excludes no card at all' do
      tickets = neu_tickets(3)
      outside = create(:ticket, project: project, title: 'Ausgefiltert', custom_attributes: { 'status' => 'Neu' })
      scope = project.tickets.order(:number).where(id: tickets.map(&:id))
      column = neu_column(selected: outside, scope: scope)
      expect(column[:tickets].map(&:title)).to eq(['Karte 1', 'Karte 2', 'Karte 3'])
      expect(column[:hidden_count]).to eq(0)
    end
  end

  describe '#capped?' do
    it 'returns false when under limit' do
      create(:ticket, project: project, custom_attributes: { 'status' => 'Neu' })
      presenter.columns # trigger build
      expect(presenter.capped?).to be false
    end
  end

  describe '#total_in_scope' do
    before do
      Prosopite.pause
      3.times { create(:ticket, project: project, custom_attributes: { 'status' => 'Neu' }) }
      Prosopite.resume
    end

    it 'returns total ticket count' do
      presenter.columns # trigger build
      expect(presenter.total_in_scope).to eq(3)
    end
  end

  # Order-aware cap: a big backlog (or pile of done tickets) must not eat the
  # MAX_TOTAL_TICKETS budget and starve the active columns. Inactive statuses sort last.
  describe 'order-aware cap' do
    let(:kanban_attribute) do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                           options: { 'allowed_values' => [
                                             { 'value' => 'Backlog', 'labels' => { 'de' => 'Backlog' }, 'system_functions' => ['is_backlog'] },
                                             { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] }
                                           ] })
    end

    it 'drops backlog tickets before active ones when capped' do
      stub_const('KanbanBoardPresenter::MAX_TOTAL_TICKETS', 2)
      Prosopite.pause
      2.times { |i| create(:ticket, project: project, title: "Active #{i}", custom_attributes: { 'status' => 'Neu' }) }
      2.times { |i| create(:ticket, project: project, title: "Parked #{i}", custom_attributes: { 'status' => 'Backlog' }) }
      Prosopite.resume

      columns = presenter.columns
      neu_col = columns.find { |c| c[:value] == 'Neu' }
      backlog_col = columns.find { |c| c[:value] == 'Backlog' }

      expect(presenter.capped?).to be true
      expect(neu_col[:tickets].size).to eq(2)
      expect(backlog_col[:tickets]).to be_empty
    end

    it 'preserves the original order as the secondary sort within a column' do
      # Inserted out of title order; an explicit title-asc scope must still drive the
      # within-column order (guards the reordered.order(*original_order) branch).
      Prosopite.pause
      create(:ticket, project: project, title: 'C', custom_attributes: { 'status' => 'Neu' })
      create(:ticket, project: project, title: 'A', custom_attributes: { 'status' => 'Neu' })
      create(:ticket, project: project, title: 'B', custom_attributes: { 'status' => 'Neu' })
      Prosopite.resume

      ordered = described_class.new(project.tickets.order(title: :asc), kanban_attribute)
      neu_col = ordered.columns.find { |c| c[:value] == 'Neu' }

      expect(neu_col[:tickets].map(&:title)).to eq(%w[A B C])
    end

    it 'does not reorder when the grouping attribute has no inactive-tagged options' do
      attr_no_inactive = create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                                              options: { 'allowed_values' => [
                                                                { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'system_functions' => ['is_new'] },
                                                                { 'value' => 'WIP', 'labels' => { 'de' => 'WIP' }, 'system_functions' => ['is_in_progress'] }
                                                              ] })
      Prosopite.pause
      create(:ticket, project: project, custom_attributes: { 'status' => 'Neu' })
      create(:ticket, project: project, custom_attributes: { 'status' => 'WIP' })
      Prosopite.resume
      presenter = described_class.new(project.tickets, attr_no_inactive)

      expect(presenter.send(:inactive_status_values)).to be_empty
      expect(presenter.columns.sum { |c| c[:tickets].size }).to eq(2)
    end
  end
end
