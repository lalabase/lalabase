# frozen_string_literal: true

require 'rails_helper'

# What: the ticket list under a search, measured through the real list: the hit count
#   (pager and data-fb-hits-total), "alle auswählen" of the bulk edit, the board, and
#   a short search sorted by a configured attribute.
# Why: three faults found in the review of #950, and a fourth in the review of this
#   fix, all on main before it.
#   1. A content or full search counted its hits before the filters: the rows were
#      right, the number was the search's alone, and "alle N auswählen" was refused
#      as list_changed because the resolved ids did not match it.
#   2. The board with a search answered 500: the grouped search relation counted to a
#      Hash, and the cap compared it with an Integer.
#   3. A search of one or two characters sorted by status or priority answered 500:
#      the short search is DISTINCT, and the configured-order sort is not in its
#      select list.
#   4. A search with the overdue filter answered 500: the due-date filter embeds the
#      list's relation as an id subquery, and the grouped search relation had more
#      than one column there. Its example stands under fault 1, since it is the same
#      list and the same count.
RSpec.describe 'Ticket list under a search: counts, board and sorting', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:other_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:user) do
    create(:user).tap do |person|
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: person, organisation: organisation, role: create(:role, organisation: organisation), active: true)
        create(:project_permission, user: person, project: project, tickets_access: 'read_write')
      end
    end
  end
  let(:mode) { 'table' }
  let(:tickets_path) { organisation_project_tickets_path(organisation, project) }

  let!(:status_definition) { select_definition(project, 'status', %w[Offen Erledigt], 'Erledigt' => ['is_completed']) }
  let!(:priority_definition) { select_definition(project, 'priority', %w[hoch mittel niedrig]) }

  # Four tickets match "Checkout", two of them done, two tagged; one does not match.
  let!(:open_high) { ticket('Checkout breaks', 'Offen', 'hoch') }
  let!(:open_low) { ticket('Checkout gateway', 'Offen', 'niedrig', tag: 'bug') }
  let!(:done_mid) { ticket('Checkout footer', 'Erledigt', 'mittel', tag: 'bug') }
  let!(:done_high) { ticket('Checkout done', 'Erledigt', 'hoch') }
  let!(:unrelated) { ticket('Plain row', 'Offen', 'mittel') }

  before do
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        # Comments that match too: the content search joins posts, so a ticket with
        # two matching comments is three rows before grouping.
        2.times { create(:post, ticket: open_high, user: user, organisation: organisation, content: 'Checkout again') }
        ViewConfiguration.create!(user: user, project: project, view_type: 'tickets', view_mode: mode,
                                  kanban_attribute_definition: status_definition,
                                  table_columns: %w[number title], list_columns: { 'cells' => [], 'metadata' => [] },
                                  header_columns: %w[assignees])
      end
    end
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def select_definition(owner, name, values, functions = {})
    ActsAsTenant.with_tenant(organisation) do
      allowed = values.map do |value|
        { 'value' => value, 'labels' => { 'de' => value }, 'system_functions' => functions.fetch(value, []) }
      end
      create(:ticket_attribute_definition, project: owner, name: name, field_type: 'select', system: true,
                                           options: { 'allowed_values' => allowed })
    end
  end

  def ticket(title, status, priority, tag: nil, due_date: nil, in_project: project)
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: in_project, organisation: organisation, title: title, content: 'No body',
                        custom_attributes: { 'status' => status, 'priority' => priority, 'due_date' => due_date }.compact).tap do |record|
          next unless tag

          found = Tag.find_by(name: tag, organisation_id: organisation.id) || create(:tag, name: tag, organisation: organisation)
          create(:tagging, tag: found, taggable: record)
        end
      end
    end
  end

  # A later page is a frame request: a full page beyond the first redirects to it.
  def list(headers: {}, **params)
    get tickets_path, params: { items: 100 }.merge(params), headers: headers
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def rows(page)
    page.css('tr[data-ticket-id]').map { |row| row['data-ticket-id'] }.uniq
  end

  def hits(page)
    page.at_css('[data-fb-hits-total]')&.[]('data-fb-hits-total')&.to_i
  end

  describe 'fault 1: the hit count of a search with a filter' do
    %w[content full].each do |search_mode|
      it "counts what the list shows, #{search_mode} search with a status filter" do
        page = list(search: 'Checkout', search_mode: search_mode, filter: { status: ['Erledigt'] })

        expect(rows(page)).to contain_exactly(done_mid.id, done_high.id)
        expect(hits(page)).to eq(2)
      end

      it "counts what the list shows, #{search_mode} search with a tag filter" do
        page = list(search: 'Checkout', search_mode: search_mode, filter: { tag: ['bug'] })

        expect(rows(page)).to contain_exactly(open_low.id, done_mid.id)
        expect(hits(page)).to eq(2)
      end
    end

    # The due-date filter embeds the list's relation as a subquery of ids; the grouped
    # search relation had more than one column there (PG::SyntaxError, a 500 on main).
    it 'counts what the list shows, search with an overdue filter' do
      past = (Date.current - 3).iso8601
      overdue = ticket('Checkout late', 'Offen', 'hoch', due_date: past)
      ticket('Checkout late but done', 'Erledigt', 'hoch', due_date: past)

      page = list(search: 'Checkout', filter: { due_date: ['overdue'] })

      expect(rows(page)).to eq([overdue.id])
      expect(hits(page)).to eq(1)
    end

    it 'counts every page, not the first one' do
      first = list(search: 'Checkout', filter: { status: ['Offen'] }, items: 1)
      second = list(search: 'Checkout', filter: { status: ['Offen'] }, items: 1, page: 2,
                    headers: { 'Turbo-Frame' => 'tickets_list_frame' })

      expect(rows(first) + rows(second)).to contain_exactly(open_high.id, open_low.id)
      expect(hits(first)).to eq(2)
    end

    it 'selects all hits of the address in the bulk edit' do
      shown = hits(list(search: 'Checkout', filter: { status: ['Erledigt'] }))

      # The summary counts once per field, on purpose (spec/support/bulk_edit_helpers.rb).
      Prosopite.pause do
        post bulk_summary_organisation_project_tickets_path(organisation, project, format: :json),
             params: { search: 'Checkout', filter: { status: ['Erledigt'] }, selection: { mode: 'all', expected_count: shown } }
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['count']).to eq(2)
    end
  end

  describe 'fault 2: the board with a search' do
    let(:mode) { 'kanban' }

    def board_cards(params)
      get tickets_path, params: params
      expect(response).to have_http_status(:ok)
      Nokogiri::HTML(response.body).css('.kanban-card').map { |card| card['data-ticket-id'] }
    end

    it 'shows the hits of a search' do
      expect(board_cards(search: 'Checkout')).to contain_exactly(open_high.id, open_low.id, done_mid.id, done_high.id)
    end

    it 'shows the hits of a search with a filter' do
      expect(board_cards(search: 'Checkout', filter: { status: ['Offen'] })).to contain_exactly(open_high.id, open_low.id)
    end

    it 'caps the board by the hits of the search and its filter' do
      stub_const('KanbanBoardPresenter::MAX_TOTAL_TICKETS', 1)

      get tickets_path, params: { search: 'Checkout', filter: { status: ['Offen'] } }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('kanban.capped_hint', shown: 1, total: 2))
    end
  end

  describe 'fault 3: a short search sorted by a configured attribute' do
    def attribute_values(page, name)
      by_id = ActsAsTenant.with_tenant(organisation) { Ticket.where(id: rows(page)).index_by(&:id) }
      rows(page).map { |id| by_id.fetch(id).custom_attributes[name] }
    end

    def statuses(page) = attribute_values(page, 'status')
    def priorities(page) = attribute_values(page, 'priority')

    # One and two characters that only the four Checkout titles contain
    %w[h Ch].each do |term|
      it "sorts the hits of #{term.inspect} by status, both ways" do
        ascending = list(search: term, sort: { column: 'custom_status', direction: 'asc' })
        expect(statuses(ascending)).to eq(%w[Offen Offen Erledigt Erledigt])

        descending = list(search: term, sort: { column: 'custom_status', direction: 'desc' })
        expect(statuses(descending)).to eq(%w[Erledigt Erledigt Offen Offen])
      end

      it "sorts the hits of #{term.inspect} by priority, with a filter" do
        page = list(search: term, filter: { status: %w[Offen Erledigt] },
                    sort: { column: 'custom_priority', direction: 'asc' })

        expect(priorities(page)).to eq(%w[hoch hoch mittel niedrig])
      end
    end
  end

  # Shapes that were right before the fix as well and must stay right: a title search in a
  # saved view resolves to the view's ids before the search join, and the short search on the
  # board was DISTINCT, which counts to a number.
  describe 'neighbouring shapes, right before the fix too' do
    # A title search runs through TicketSearchQuery only with a saved view; an edited
    # view applies its conditions as list filters, after the search.
    it 'counts what the list shows, title search in an edited view' do
      view = ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder, organisation: organisation, project: project, user: user, target_object_type: 'Ticket').tap do |folder|
          group = create(:smart_folder_rule_group, smart_folder: folder)
          create(:smart_folder_rule, smart_folder_rule_group: group, field: 'tag', operator: 'has_any_of', value: 'bug')
        end
      end

      page = list(search: 'Checkout', search_mode: 'title_only', smart_folder_id: view.id,
                  filter: { tag: ['bug'], status: ['Erledigt'] })

      expect(rows(page)).to contain_exactly(done_mid.id)
      expect(hits(page)).to eq(1)
    end

    it 'sorts a title search in a saved view by status' do
      view = ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder, organisation: organisation, project: project, user: user, target_object_type: 'Ticket').tap do |folder|
          group = create(:smart_folder_rule_group, smart_folder: folder)
          create(:smart_folder_rule, smart_folder_rule_group: group, field: 'tag', operator: 'has_any_of', value: 'bug')
        end
      end

      page = list(search: 'Checkout', search_mode: 'title_only', smart_folder_id: view.id,
                  sort: { column: 'custom_status', direction: 'asc' })

      expect(rows(page)).to eq([open_low.id, done_mid.id])
      expect(hits(page)).to eq(2)
    end

    context 'on the board' do
      let(:mode) { 'kanban' }

      it 'shows a short search' do
        get tickets_path, params: { search: 'Ch' }

        expect(response).to have_http_status(:ok)
        cards = Nokogiri::HTML(response.body).css('.kanban-card').map { |card| card['data-ticket-id'] }
        expect(cards).to contain_exactly(open_high.id, open_low.id, done_mid.id, done_high.id)
      end
    end
  end

  describe 'the cost of a searched list' do
    # Queries sent to the database for the list, after a first request has warmed what is
    # loaded once per process. Answers from the query cache count too: a lookup repeated per
    # row is the same SQL each time.
    def queries_for(**params)
      list(**params)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == 'SCHEMA' }
      page = nil
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { page = list(**params) }
      [count, rows(page).size]
    end

    it 'does not grow with the rows' do
      small, small_rows = queries_for(search: 'Checkout', filter: { status: ['Offen'] })
      4.times { |n| ticket("Checkout extra #{n}", 'Offen', 'hoch', tag: 'bug') }
      large, large_rows = queries_for(search: 'Checkout', filter: { status: ['Offen'] })

      expect([small_rows, large_rows]).to eq([2, 6])
      expect(large).to eq(small)
    end
  end

  describe 'what the reader may not see' do
    it 'counts the hits of this project only' do
      ticket('Checkout elsewhere', 'Erledigt', 'hoch', in_project: other_project)

      page = list(search: 'Checkout', filter: { status: ['Erledigt'] })
      expect(rows(page)).to contain_exactly(done_mid.id, done_high.id)
      expect(hits(page)).to eq(2)

      get organisation_project_tickets_path(organisation, other_project), params: { search: 'Checkout' }
      expect(response).not_to have_http_status(:ok)
    end

    # A private comment matches for its reader only (Post.readable_by): the hit and the
    # count leave it out, under a filter as well.
    %w[content full].each do |search_mode|
      it "leaves out a match in a private comment of someone else, #{search_mode} search with a filter" do
        Prosopite.pause do
          ActsAsTenant.with_tenant(organisation) do
            author = create(:user)
            create(:membership, user: author, organisation: organisation, role: create(:role, organisation: organisation), active: true)
            create(:post, ticket: open_low, user: author, organisation: organisation, content: 'Geheimplan offen')
            create(:post, ticket: unrelated, user: author, organisation: organisation, content: 'Geheimplan privat',
                          is_private: true, visible_to_user_id: author.id)
          end
        end

        page = list(search: 'Geheimplan', search_mode: search_mode, filter: { status: ['Offen'] })

        expect(rows(page)).to eq([open_low.id])
        expect(hits(page)).to eq(1)
      end
    end
  end
end
