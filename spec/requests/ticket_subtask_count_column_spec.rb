# frozen_string_literal: true

require 'rails_helper'

# The "Subs" column, seen from the list that renders it. The cache spec proves
# the numbers; this proves the wiring: the cell shows "done/total" of a ticket's
# DIRECT sub-tickets, also on a sub-ticket with sub-tickets of its own, stays
# empty for a ticket without any, the page preloads, and the single-row
# re-render after a save still counts.
RSpec.describe 'Ticket table: sub-ticket column', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { ActsAsTenant.with_tenant(organisation) { create(:user) } }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:parent) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user) } }

  let(:table_columns) { %w[number title subtask_count] }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation,
                        role: create(:admin_role, organisation: organisation))
    create(:ticket_attribute_definition,
           project: project, name: 'status', field_type: 'select', system: true,
           options: { 'allowed_values' => [
             { 'value' => 'Offen', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] },
             { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
           ] })
    ViewConfiguration.create!(user: user, project: project, view_type: 'tickets',
                              table_columns: table_columns,
                              list_columns: { 'cells' => [], 'metadata' => [] },
                              header_columns: %w[assignees])
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def child(status)
    create(:ticket, project: project, creator: user, parent: parent, custom_attributes: { 'status' => status })
  end

  def get_index
    get organisation_project_tickets_path(organisation, project)
    response.body
  end

  # Cell-scoped: the detail page's "1 von 3 erledigt" is not on this page, but
  # a page-wide match would not notice the cell being gone.
  def cells(body = response.body)
    Nokogiri::HTML(body).css('td.subtask_count-column').map { |cell| cell.text.strip }
  end

  it 'offers the column in the picker under its own name' do
    keys = ViewConfiguration.available_columns_for(project, 'tickets', user: user).to_h { |c| [c[:key], c[:label]] }
    expect(keys['subtask_count']).to eq('Subs')
  end

  it 'shows done and total on the parent and nothing on its sub-tickets' do
    child('Erledigt')
    child('Offen')
    child('Offen')

    get_index
    expect(response).to have_http_status(:ok)
    # Four rows: the parent with its count, three children with an empty cell.
    expect(cells.sort).to eq(['', '', '', '1/3'])
  end

  # Sub-tasks nest to any depth. Each row counts its direct children: the
  # grandchild is the sub-ticket's, not the root's.
  it "shows a sub-ticket's own children and leaves them out of the root's count" do
    sub = child('Offen')
    create(:ticket, project: project, creator: user, parent: sub, custom_attributes: { 'status' => 'Erledigt' })
    create(:ticket, project: project, creator: user, parent: sub, custom_attributes: { 'status' => 'Offen' })
    child('Erledigt')

    get_index
    expect(response).to have_http_status(:ok)
    by_row = Nokogiri::HTML(response.body).css('tr[data-ticket-id]').to_h do |row|
      [row['data-ticket-id'], row.at_css('td.subtask_count-column')&.text&.strip]
    end
    expect(by_row[parent.id]).to eq('1/2')
    expect(by_row[sub.id]).to eq('1/2')
    # The other sub-ticket and both grandchildren have no children: empty.
    expect(by_row.values.sort).to eq(['', '', '', '1/2', '1/2'])
  end

  it 'explains the number in the cell title' do
    child('Erledigt')

    get_index
    cell = Nokogiri::HTML(response.body).at_css('td.subtask_count-column span[title]')
    expect(cell['title']).to eq(I18n.t('views.organisations.tickets.shared.subtasks.progress', done: 1, total: 1))
  end

  it 'lines the number up on the right, head included' do
    child('Offen')

    get_index
    doc = Nokogiri::HTML(response.body)
    head = doc.css('thead th').find { |th| th.text.strip == 'Subs' }
    expect(head).to be_present
    expect(head['class']).to include('text-end')
    expect(doc.at_css('td.subtask_count-column')['class']).to include('text-end')
  end

  # Three parents with a child each: per-row counting would run six grouped
  # counts, the preload runs two (all children, the done ones).
  it 'counts a page in one pass, not once per row' do
    Prosopite.pause do
      3.times { create(:ticket, project: project, creator: user, parent: create(:ticket, project: project, creator: user)) }
    end

    grouped = 0
    counter = ->(*, payload) { grouped += 1 if payload[:sql].include?('GROUP BY "tickets"."parent_id"') }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { get_index }

    expect(response).to have_http_status(:ok)
    expect(cells.count('1/1') + cells.count('0/1')).to eq(3)
    expect(grouped).to eq(2)
  end

  context 'without the column' do
    let(:table_columns) { %w[number title] }

    # The page is registered either way (TicketsHelper#register_ticket_count_page); without a
    # cell that reads it, nothing is counted. Asked of the cache, not of the SQL: a count in
    # another shape would pass a query matcher. Both ways in: a read (fetch) and a page loaded
    # by hand (preload, review round 6 of #949). Not seen here: a count that goes around the
    # cache (Ticket.where(parent_id: ...) in a view); per row, Prosopite catches that.
    it 'does not count at all' do
      child('Offen')
      caches = []
      allow(Tickets::SubtaskCountsCache).to receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap do |cache|
          allow(cache).to receive(:fetch).and_call_original
          allow(cache).to receive(:preload).and_call_original
          caches << cache
        end
      end

      get_index

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).css('tr[data-ticket-id]')).to be_present
      expect(caches).to be_present
      caches.each do |cache|
        expect(cache).not_to have_received(:fetch)
        expect(cache).not_to have_received(:preload)
      end
    end
  end

  # The caller without a preload: the row re-rendered after a post.
  it 'still counts in a single row re-rendered on its own' do
    child('Erledigt')
    child('Offen')

    post organisation_project_ticket_posts_path(organisation, project, parent),
         params: { post: { content: 'Test post content' } },
         headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

    expect(response).to have_http_status(:ok)
    expect(cells).to eq(['1/2'])
  end

  # The item under the title has two ways out, and they must stay apart: a
  # sub-ticket's write updates the item's TEXT on its parent, and a text update
  # cannot touch an attribute. So `hidden` says "not pinned" (fixed with the
  # row) and an empty item says "no value" (layout.css reads :empty).
  describe 'the item under the title' do
    def item(ticket)
      Nokogiri::HTML(response.body)
              .at_css("tr[data-ticket-id='#{ticket.id}'] .ticket-meta__item[data-meta-column='subtask_count']")
    end

    it 'is empty but not hidden while pinned without a value' do
      ViewConfiguration.find_by!(user: user, project: project).update!(pinned_columns: %w[subtask_count])
      parent

      get_index
      expect(item(parent)).to be_present
      expect(item(parent).has_attribute?('hidden')).to be(false)
      # Nothing at all, not even a space: :empty would not match.
      expect(item(parent).inner_html).to eq('')
    end

    it 'is hidden while not pinned, whatever its value' do
      child('Offen')

      get_index
      expect(item(parent).has_attribute?('hidden')).to be(true)
    end

    it 'is read by the stylesheet as no value when empty' do
      css = Rails.root.join('app/assets/stylesheets/layout.css').read
      shown = css.scan(/\.ticket-meta__item:nth-child\([^)]*\)[^\s{~]*/)
      expect(shown).not_to be_empty
      expect(shown).to all(include(':not([hidden]):not(:empty)'))
    end
  end

  # The parent's "1/3" depends on OTHER rows. Every write that answers with a
  # single row (or none) must redraw the parent's row as well, or the column
  # shows the old count until the list is reloaded (review of #927). Read from
  # the stream aimed at the PARENT's row, never from the whole response: the
  # child's own row is in the same response.
  describe "the parent's row after a change to a sub-ticket" do
    let(:stream_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

    # Only the pieces that depend on the children go out, never the parent's
    # whole row: a whole row needs what only the list knows (the view's
    # columns, the unread counts), and lost both (second review of #927).
    def parent_stream(target)
      Nokogiri::HTML(response.body).css('turbo-stream').find { |node| node['targets'] == target }
    end

    def parent_cell(of: parent)
      parent_stream("tr[data-ticket-id='#{of.id}'] td[data-column='subtask_count']")&.text&.strip
    end

    def parent_meta(of: parent)
      parent_stream("tr[data-ticket-id='#{of.id}'] .ticket-meta__item[data-meta-column='subtask_count']")&.text&.strip
    end

    it 'counts a sub-ticket added with the quick-add' do
      child('Erledigt')

      post organisation_project_ticket_subtasks_path(organisation, project, parent),
           params: { title: 'Noch eins' }, headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(parent_cell).to eq('1/2')
      expect(parent_meta).to eq('Subs 1/2')
    end

    it 'counts the first sub-ticket added with the quick-add' do
      post organisation_project_ticket_subtasks_path(organisation, project, parent),
           params: { title: 'Das erste' }, headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(parent_cell).to eq('0/1')
    end

    it 'counts a status set in the edit form' do
      sub = child('Offen')

      patch organisation_project_ticket_path(organisation, project, sub),
            params: { ticket: { title: sub.title, custom_attributes: { status: 'Erledigt' } } }, headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(parent_cell).to eq('1/1')
    end

    it 'counts a status set in the head or on the board' do
      sub = child('Offen')

      patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, sub),
            params: { attribute_name: 'status', value: 'Erledigt' }, headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(parent_cell).to eq('1/1')
    end

    it 'counts a status set while commenting' do
      sub = child('Offen')

      post organisation_project_ticket_posts_path(organisation, project, sub),
           params: { post: { content: 'Fertig' }, ticket_status: 'Erledigt' }, headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(parent_cell).to eq('1/1')
    end

    it 'drops a deleted sub-ticket from the count' do
      child('Erledigt')
      sub = child('Offen')

      delete organisation_project_ticket_path(organisation, project, sub), headers: stream_headers

      expect(response).to have_http_status(:ok)
      expect(parent_cell).to eq('1/1')
    end

    # A saved ticket keeps its parent (Ticket#parent_unchanged): an edit that names
    # another parent changes nothing, so no row has a new count to show.
    it 'keeps the parent when an edit names another one, and the other stays empty' do
      new_parent = create(:ticket, project: project, creator: user)
      sub = child('Offen')

      patch organisation_project_ticket_path(organisation, project, sub),
            params: { ticket: { title: sub.title, parent_id: new_parent.id } }, headers: stream_headers

      expect(sub.reload.parent_id).to eq(parent.id)
      expect(parent_cell(of: new_parent).to_s).to eq('')
    end

    # Finding 2 of the second review: the unread dot on the parent's number
    # is loaded only by the index, so a redrawn row lost it.
    it "never replaces the parent's whole row" do
      sub = child('Offen')

      patch update_kanban_attribute_organisation_project_ticket_path(organisation, project, sub),
            params: { attribute_name: 'status', value: 'Erledigt' }, headers: stream_headers

      expect(response).to have_http_status(:ok)
      targets = Nokogiri::HTML(response.body).css('turbo-stream').map { |node| node['targets'].to_s }
      expect(targets).to include("tr[data-ticket-id='#{sub.id}']")
      expect(targets.grep(/#{parent.id}/)).to all(match(/td\[data-column=|ticket-meta__item/))
    end

    # Finding 1: no form in the detail carries the active folder, so the
    # server cannot know whether a folder shows the column the base view
    # hides. The update does not ask: where the cell is missing, it has no target.
    context 'while the base view does not show the column' do
      let(:table_columns) { %w[number title] }

      it 'still sends the count, for a folder that shows it' do
        post organisation_project_ticket_subtasks_path(organisation, project, parent),
             params: { title: 'Im Ordner' }, headers: stream_headers

        expect(response).to have_http_status(:ok)
        expect(parent_cell).to eq('0/1')
      end
    end
  end
end
