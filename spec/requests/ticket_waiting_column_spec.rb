# frozen_string_literal: true

require 'rails_helper'

# The waiting state outside the ticket page (doc/ticket_relations_plan.md, revision 4, §8.3,
# §8.4): the "Wartet" column of the table, the hourglass on the board card and in the phone
# row, and the open ticket's own row and card after a relation is added or removed.
#
# The numbers are Tickets::Waiting's (its spec proves them); this proves the wiring: where the
# mark shows, that a list, a phone page and a board are counted in one go, and that the table
# without the column does not count at all. Readability is ticket_waiting_visibility_spec's.
RSpec.describe 'Ticket list: waiting state', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { new_project('Kundenportal') }
  let(:other_project) { new_project('Backoffice') }
  let(:user) { member(tickets: { project => 'read_write', other_project => 'read_only' }) }

  let(:table_columns) { %w[number title waiting] }
  let(:view_mode) { 'table' }

  before do
    # "Erledigt" is done in the list's project and still open in the other one (plan §5.2).
    status_field(project, 'Offen' => 'is_new', 'Erledigt' => 'is_completed')
    status_field(other_project, 'Offen' => 'is_new', 'Erledigt' => 'is_in_progress', 'Geprüft' => 'is_completed')
    ActsAsTenant.with_tenant(organisation) do
      ViewConfiguration.create!(user: user, project: project, view_type: 'tickets', view_mode: view_mode,
                                table_columns: table_columns, list_columns: { 'cells' => [], 'metadata' => [] },
                                header_columns: %w[assignees])
    end
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def new_project(name)
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: name) }
  end

  def status_field(project, options)
    allowed_values = options.map do |value, function|
      { 'value' => value, 'labels' => { 'de' => value }, 'system_functions' => [function] }
    end
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                           options: { 'allowed_values' => allowed_values })
    end
  end

  def member(tickets:)
    person = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation)
      create(:membership, user: person, organisation: organisation, role: role, active: true)
      tickets.each { |project, access| create(:project_permission, user: person, project: project, tickets_access: access) }
    end
    person
  end

  def ticket(status = 'Offen', in_project: project, title: nil)
    attributes = { project: in_project, custom_attributes: { 'status' => status } }
    attributes[:title] = title if title
    Prosopite.pause { ActsAsTenant.with_tenant(organisation) { create(:ticket, **attributes) } }
  end

  def link(source, target, type = :blocks)
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        TicketRelation.create!(source_ticket: source, target_ticket: target, relation_type: type)
      end
    end
  end

  def get_index(**params)
    get organisation_project_tickets_path(organisation, project, **params)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  # Every query of the waiting state names the relations table: the done values of the
  # projects involved (their ids come from the edges) and the aggregation.
  def waiting_queries(&)
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].include?('ticket_relations') }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  # Every query of a request, for the contract that does not trust a table name: what the
  # column adds must be the same for 3 rows and for 25 (review of #949).
  def all_queries(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == 'SCHEMA' || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  def show_columns(keys)
    ActsAsTenant.with_tenant(organisation) do
      ViewConfiguration.find_by!(user: user, project: project).update!(table_columns: keys)
    end
  end

  # Capybara's matchers on a Nokogiri node. A stream's markup is the content of its <template>,
  # which Capybara's HTML5 parser keeps out of the tree it searches.
  def markup(node)
    template = node.at_css('template')
    Capybara.string(template ? template.inner_html : node.to_html)
  end

  let(:mark_label) { ->(count) { I18n.t('views.organisations.tickets.shared.relations.waiting_mark', count: count) } }

  describe 'the column in the table' do
    def cell(doc, ticket)
      doc.at_css("tr[data-ticket-id='#{ticket.id}'] td[data-column='waiting']")
    end

    it 'is offered in the picker under its own name, and is no default' do
      columns, defaults = ActsAsTenant.with_tenant(organisation) do
        [ViewConfiguration.available_columns_for(project, 'tickets', user: user).index_by { |c| c[:key] },
         ViewConfiguration.default_columns_for(project)]
      end
      expect(columns['waiting']).to include(label: 'Wartet', type: 'count')
      expect(defaults).not_to include('waiting')
      expect(columns['waiting'][:sortable]).to be_falsy
    end

    it 'shows the hourglass and the number of open tickets a row waits on, and nothing elsewhere' do
      waiter = ticket
      lone = ticket
      link(ticket, waiter)
      # Another project, where "Erledigt" is not done: it still holds the row up.
      link(ticket('Erledigt', in_project: other_project), waiter)
      link(ticket('Erledigt'), waiter)

      doc = get_index
      expect(cell(doc, waiter).text.strip).to eq('2')
      expect(markup(cell(doc, waiter))).to have_css(%([role="img"][title="#{mark_label.call(2)}"] i.bi-hourglass-split))
      expect(cell(doc, lone).text.strip).to eq('')
    end

    it 'counts tickets, not edges' do
      waiter = ticket
      blocker = ticket
      link(blocker, waiter, :blocks)
      link(blocker, waiter, :precedes)

      expect(cell(get_index, waiter).text.strip).to eq('1')
    end

    it 'stays empty on a done ticket, whatever still points at it' do
      done = ticket('Erledigt')
      link(ticket, done)

      expect(cell(get_index, done).text.strip).to eq('')
    end

    it 'lines the number up on the right, head included, and cannot be sorted by' do
      link(ticket, ticket)

      doc = get_index
      head = doc.css('thead th').find { |th| th.text.strip == 'Wartet' }
      expect(head).to be_present
      expect(head['class']).to include('text-end')
      expect(markup(head)).to have_no_css('a')
    end

    it 'says it in words under the title while pinned' do
      ActsAsTenant.with_tenant(organisation) do
        ViewConfiguration.find_by!(user: user, project: project).update!(pinned_columns: %w[waiting])
      end
      waiter = ticket
      link(ticket, waiter)

      item = get_index.at_css("tr[data-ticket-id='#{waiter.id}'] .ticket-meta__item[data-meta-column='waiting']")
      expect(item.text.strip).to eq(I18n.t('views.organisations.tickets.tickets_results.waiting_meta', count: 1))
    end

    it 'shows in a folder that has its own columns' do
      folder = ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder, user: user, organisation: organisation, project: project, target_object_type: 'Ticket',
                              display_columns: { 'table_columns' => %w[number title waiting] }).tap do |smart_folder|
          group = create(:smart_folder_rule_group, smart_folder: smart_folder)
          create(:smart_folder_rule, smart_folder_rule_group: group, field: 'title', operator: 'contains', value: 'Wartend')
        end
      end
      ActsAsTenant.with_tenant(organisation) do
        ViewConfiguration.find_by!(user: user, project: project).update!(table_columns: %w[number title])
      end
      waiter = ticket(title: 'Wartend auf Freigabe')
      link(ticket, waiter)

      expect(cell(get_index(smart_folder_id: folder.id), waiter).text.strip).to eq('1')
    end

    # Plan §12, review 5: one aggregation plus fixed preparation, whatever the number of rows,
    # with or without relations. A query per cell would grow with the page.
    it 'counts a page of 3 and a page of 25 in the same number of queries' do
      counts = Prosopite.pause do
        [3, 25].flat_map do |size|
          ActsAsTenant.without_tenant { Ticket.where(project: project).delete_all }
          page = Array.new(size) { ticket }
          without = waiting_queries { get_index(limit: 50) }
          link(ticket, page.first)
          with = waiting_queries { get_index(limit: 50) }
          expect(cell(Nokogiri::HTML(response.body), page.first).text.strip).to eq('1')
          [without, with]
        end
      end

      expect(counts.uniq.size).to eq(1)
      expect(counts.first).to be_positive
    end

    # The same contract without trusting the table name: the column costs the same number of
    # queries on a page of 3 as on a page of 25, whatever those queries read.
    it 'adds the same number of queries to a page of 3 and a page of 25' do
      added = Prosopite.pause do
        [3, 25].map do |size|
          ActsAsTenant.without_tenant { Ticket.where(project: project).delete_all }
          page = Array.new(size) { ticket }
          link(ticket, page.first)
          show_columns(%w[number title])
          get_index(limit: 50)
          without = all_queries { get_index(limit: 50) }
          show_columns(%w[number title waiting])
          get_index(limit: 50)
          with = all_queries { get_index(limit: 50) }
          expect(cell(Nokogiri::HTML(response.body), page.first).text.strip).to eq('1')
          with - without
        end
      end

      expect(added.uniq.size).to eq(1)
      expect(added.first).to be_positive
    end

    context 'without the column' do
      let(:table_columns) { %w[number title] }

      it 'does not count at all' do
        link(ticket, ticket)
        expect(Tickets::Waiting).not_to receive(:counts_for)

        doc = get_index
        expect(doc.css('tr[data-ticket-id]').size).to eq(2)
      end
    end
  end

  describe 'the phone row' do
    def row(doc, ticket)
      doc.at_css(".mobile-ticket-row[data-ticket-id='#{ticket.id}']")
    end

    it 'shows the hourglass next to the number, without the column being chosen' do
      ActsAsTenant.with_tenant(organisation) do
        ViewConfiguration.find_by!(user: user, project: project).update!(table_columns: %w[number title])
      end
      waiter = ticket
      lone = ticket
      link(ticket, waiter)
      link(ticket, waiter)

      doc = get_index(viewport: 'mobile')
      meta = row(doc, waiter).at_css('.mobile-ticket-meta')
      expect(meta.element_children.first.text).to eq("##{waiter.number}")
      mark = meta.element_children[1]
      expect(mark['class']).to include('ticket-waiting-mark')
      expect(mark['aria-label']).to eq(mark_label.call(2))
      expect(mark['title']).to eq(mark_label.call(2))
      # The phone shows the sign, not the number.
      expect(mark.text.strip).to eq('')
      expect(row(doc, lone)).to be_present
      expect(markup(row(doc, lone))).to have_no_css('.ticket-waiting-mark')
    end

    it 'counts a page of 3 and a page of 25 in the same number of queries' do
      counts = Prosopite.pause do
        [3, 25].map do |size|
          ActsAsTenant.without_tenant { Ticket.where(project: project).delete_all }
          page = Array.new(size) { ticket }
          link(ticket, page.first)
          waiting_queries { get_index(viewport: 'mobile', limit: 50) }
        end
      end

      last = ActsAsTenant.without_tenant { Ticket.where(project: project).order(:created_at).first }
      expect(row(Nokogiri::HTML(response.body), last)).to be_present
      expect(counts.uniq.size).to eq(1)
      expect(counts.first).to be_positive
    end
  end

  describe 'the board card' do
    let(:view_mode) { 'kanban' }

    def card(doc, ticket)
      doc.at_css("#kanban-card-#{ticket.id}")
    end

    it 'shows the hourglass without a number, labelled, and nothing on a card that waits on nothing' do
      waiter = ticket
      lone = ticket
      link(ticket, waiter)
      link(ticket, waiter)

      doc = get_index
      mark = card(doc, waiter).at_css('.ticket-waiting-mark')
      expect(mark['aria-label']).to eq(mark_label.call(2))
      expect(mark['title']).to eq(mark_label.call(2))
      expect(mark.text.strip).to eq('')
      expect(card(doc, lone)).to be_present
      expect(markup(card(doc, lone))).to have_no_css('.ticket-waiting-mark')
    end

    # The filter bar reloads the board as a frame (TicketsController, _kanban_list_frame).
    it 'shows the sign when the board comes back as a frame' do
      waiter = ticket
      link(ticket, waiter)

      get organisation_project_tickets_path(organisation, project), headers: { 'Turbo-Frame' => 'tickets_list_frame' }

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css('turbo-frame#tickets_list_frame')).to be_present
      expect(card(doc, waiter).at_css('.ticket-waiting-mark')['title']).to eq(mark_label.call(1))
    end

    # One count for every card of every column, not one per column.
    it 'counts a board of 3 and a board of 25 in the same number of queries' do
      counts = Prosopite.pause do
        [3, 25].map do |size|
          ActsAsTenant.without_tenant { Ticket.where(project: project).delete_all }
          page = Array.new(size) { |index| ticket(index.even? ? 'Offen' : 'Erledigt') }
          link(ticket, page.first)
          waiting_queries { get_index }
        end
      end

      expect(Nokogiri::HTML(response.body).css('.kanban-card').size).to be > 20
      expect(counts.uniq.size).to eq(1)
      expect(counts.first).to be_positive
    end
  end

  # Plan §8.3: a relation added or removed on ticket T redraws T's own row (table and phone)
  # and T's own card. Nothing for the other ticket (ticket_waiting_visibility_spec).
  describe "the open ticket's own row and card after a relation changes" do
    let(:shown) { ticket }
    let(:blocker) { ticket(in_project: other_project) }

    def post_link(kind: 'blocked_by')
      post organisation_project_ticket_relations_path(organisation, project, shown),
           params: { other_ticket_id: blocker.id, kind: kind }, as: :turbo_stream
      expect(response).to have_http_status(:ok)
      Nokogiri::HTML(response.body)
    end

    def delete_link
      relation = ActsAsTenant.without_tenant { TicketRelation.find_by!(target_ticket_id: shown.id) }
      delete organisation_project_ticket_relation_path(organisation, project, shown, relation), as: :turbo_stream
      expect(response).to have_http_status(:ok)
      Nokogiri::HTML(response.body)
    end

    def stream(doc, attribute, value)
      doc.css('turbo-stream').find { |node| node[attribute] == value }
    end

    def row_stream(doc)
      stream(doc, 'targets', "tr[data-ticket-id='#{shown.id}']")
    end

    def phone_stream(doc)
      stream(doc, 'targets', ".mobile-ticket-row[data-ticket-id='#{shown.id}']")
    end

    def card_stream(doc)
      stream(doc, 'target', "kanban-card-#{shown.id}")
    end

    def row_count(doc)
      row_stream(doc).at_css("td[data-column='waiting']").text.strip
    end

    def expect_waiting(doc)
      expect(row_count(doc)).to eq('1')
      expect(markup(phone_stream(doc))).to have_css('.ticket-waiting-mark')
      expect(card_stream(doc)['action']).to eq('replace')
      expect(markup(card_stream(doc))).to have_css('.ticket-waiting-mark')
    end

    # All three targets in all three steps (review of #949): a card or phone row right only on
    # the first create would pass a check of the table alone.
    it 'redraws row, phone row and card: first added, last removed, added again' do
      expect_waiting(post_link)

      doc = delete_link
      expect(row_count(doc)).to eq('')
      expect(markup(phone_stream(doc))).to have_css('.mobile-ticket-meta')
      expect(markup(phone_stream(doc))).to have_no_css('.ticket-waiting-mark')
      expect(markup(card_stream(doc))).to have_css('.kanban-card')
      expect(markup(card_stream(doc))).to have_no_css('.ticket-waiting-mark')

      expect_waiting(post_link)
    end

    # The open ticket's card keeps its mark from the first paint, not only once its
    # controller has read the address.
    it 'marks the replaced card as the open one' do
      expect(markup(card_stream(post_link))).to have_css('.kanban-card.selected-row')
    end

    it 'redraws the row of a ticket that now holds another up, with nothing to count' do
      doc = post_link(kind: 'blocks')
      expect(row_stream(doc)).to be_present
      expect(row_count(doc)).to eq('')
    end
  end
end
