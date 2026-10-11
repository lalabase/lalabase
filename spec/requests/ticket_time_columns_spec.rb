# frozen_string_literal: true

require 'rails_helper'

# The two booked-time columns, seen from the list that renders them. The service
# specs prove the numbers; this proves the wiring, and above all that it holds for
# EVERY caller: the list preloads a page in one query, and the single-row
# re-render after a save, which never runs that preload, still shows the value
# instead of an empty cell.
RSpec.describe 'Ticket table: booked time columns', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { ActsAsTenant.with_tenant(organisation) { create(:user) } }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user) } }
  let(:untracked_ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user) } }

  let(:table_columns) { %w[number title time_spent billing_status] }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation,
                        role: create(:admin_role, organisation: organisation))
    ViewConfiguration.create!(user: user, project: project, view_type: 'tickets',
                              table_columns: table_columns,
                              list_columns: { 'cells' => [], 'metadata' => [] },
                              header_columns: %w[assignees])
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def book(minutes:, on: ticket, billed: false, grouped: false, invoice: nil)
    group = grouped ? create(:time_session_group, organisation: organisation) : nil
    create(:time_session, project: project, organisation: organisation, creator: user,
                          ticket: on, duration: minutes, billed: billed, invoice_number: invoice,
                          time_session_group_id: group&.id, occurred_on: 2.days.ago)
  end

  def get_index
    get organisation_project_tickets_path(organisation, project)
    response.body
  end

  # Cell-scoped, never a page-wide include: the word "abgerechnet" also lives in the
  # filter bar and the sidebar, and a page-wide match would call that a pass.
  def cells(selector, body = response.body)
    Nokogiri::HTML(body).css(selector).map { |cell| cell.text.strip }
  end

  describe 'the time column' do
    it 'shows the total booked on the ticket' do
      book(minutes: 45)
      book(minutes: 90)

      get_index
      expect(cells('td.time_spent-column')).to include('02:15')
    end

    it 'links into the time list, filtered to this ticket and with the list defaults neutralised' do
      book(minutes: 30)

      body = get_index
      expect(body).to include("ticket_id=#{ticket.id}")
      # date_range=all and the three status filters: without them the list would
      # open on a different set than the number promises (current month, billed hidden).
      expect(body).to include('date_range=all')
      TimeSession::BILLING_STATUS_FILTERS.each { |bucket| expect(body).to include(bucket) }
    end

    it 'shows no duration for a ticket with nothing booked' do
      untracked_ticket
      book(minutes: 30)

      get_index
      # Two ticket rows, one of them booked: exactly one cell carries a link.
      expect(cells('td.time_spent-column').size).to eq(2)
      expect(cells('td.time_spent-column a').size).to eq(1)
    end
  end

  describe 'the billing column' do
    {
      'without_billing' => {},
      'in_billing' => { grouped: true },
      'billed' => { billed: true, invoice: 'INV-1' }
    }.each do |state, args|
      it "names #{state} with the same word the time list uses" do
        book(minutes: 60, **args)

        get_index
        expect(cells('td.billing_status-column'))
          .to include(I18n.t("views.time_sessions.billing_status.#{state}"))
      end
    end

    # The column used to say only "Gemischt" and needed a short form because the
    # long sentence widened it past every other cell. It now says how far the
    # ticket has got, which is shorter AND more than the old word carried.
    it 'says how far a ticket with two states at once has got' do
      book(minutes: 60, billed: true, invoice: 'INV-2')
      book(minutes: 30)

      get_index

      expect(cells('td.billing_status-column')).to include('teilweise 67 %')
    end

    # The one picture for three surfaces: the same bar the time list draws, with
    # the same minutes in its label (plan §4).
    it 'draws the share bar the time list draws, minutes and all' do
      book(minutes: 60, billed: true, invoice: 'INV-3')
      book(minutes: 30)

      get_index
      labels = Nokogiri::HTML(response.body).css('td.billing_status-column [role="img"]').map { |n| n['aria-label'] }

      # ⚠️ The three words have ONE owner (views.time_sessions.billing_status,
      # S1). Read from it, not typed: they changed once already, and a literal
      # here fails in a file that has nothing to do with the change.
      expect(labels).to include("#{I18n.t('views.time_sessions.billing_status.billed')}: 01:00 · #{I18n.t('views.time_sessions.billing_status.without_billing')}: 00:30")
    end

    it 'says the plain word when only one state is present' do
      book(minutes: 60, grouped: true)

      get_index

      expect(cells('td.billing_status-column')).to include(I18n.t('views.time_sessions.billing_status.in_billing'))
    end

    it 'shows no pill for a ticket with nothing booked' do
      untracked_ticket
      get_index

      cell_texts = cells('td.billing_status-column')
      # Nothing at all: a cell without a value carries no placeholder since
      # 07.09.2026 (TicketColumnsHelper, "A cell without a value shows NOTHING").
      expect(cell_texts).to all(be_blank)
      TimeSession::BILLING_STATUS_FILTERS.each do |bucket|
        expect(cell_texts).not_to include(I18n.t("views.time_sessions.billing_status.#{bucket}"))
      end
    end
  end

  # The rights property at the surface: the gate is ViewConfiguration's
  # available_columns, so a stored column key from a time the user still had
  # access renders nothing rather than a number they may not see.
  describe 'a user who may see none of the project\'s booked time' do
    let(:outsider) { ActsAsTenant.with_tenant(organisation) { create(:user) } }

    before do
      create(:membership, user: outsider, organisation: organisation)
      ViewConfiguration.create!(user: outsider, project: project, view_type: 'tickets',
                                table_columns: table_columns,
                                list_columns: { 'cells' => [], 'metadata' => [] },
                                header_columns: %w[assignees])
      book(minutes: 240)
      sign_in outsider
    end

    it 'gets no time cell, although the column key is stored in their configuration' do
      body = get_index

      expect(body).not_to include('04:00')
      expect(body).not_to include('time_spent-column')
    end

    it 'gets no billing pill either' do
      get_index

      expect(cells('td.billing_status-column')).to be_empty
    end
  end

  describe 'the query cost' do
    # The whole reason the loader exists. Noise FIRST: real tickets with real
    # sessions, so a short circuit cannot make the guard pass by finding nothing.
    it 'loads a page of tickets with one totals query, not one per row' do
      Prosopite.pause do
        5.times do
          t = create(:ticket, project: project, creator: user)
          book(minutes: 30, on: t)
          book(minutes: 15, on: t, grouped: true)
        end
      end

      expect(TimeSessions::SubjectTotals).to receive(:call).once.and_call_original

      get_index
    end
  end

  # The caller that has no preload. This is the trap the codebase keeps hitting:
  # one owner removes the copies, not the wiring, so every surface needs its own
  # example.
  describe 'a single row re-rendered on its own' do
    it 'still shows the booked time after a post is created' do
      book(minutes: 75)

      post organisation_project_ticket_posts_path(organisation, project, ticket),
           params: { post: { content: 'Test post content' } },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      # Read the CELL, not the response: the same duration is rendered by the
      # ticket header further up this very stream, and a page-wide match would
      # go on passing with the row's value gone.
      expect(cells('td.time_spent-column')).to eq(['01:15'])
    end

    # Grouped on purpose: this same response also renders
    # TimeSessionBillingStatusComponent further up, which could not be rendered
    # under rspec until it went through `helpers` for its route (same commit).
    it 'still shows the billing state in that same row' do
      book(minutes: 30, grouped: true)

      post organisation_project_ticket_posts_path(organisation, project, ticket),
           params: { post: { content: 'Another post' } },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(cells('td.billing_status-column'))
        .to eq([I18n.t('views.time_sessions.billing_status.in_billing')])
    end
  end
end
