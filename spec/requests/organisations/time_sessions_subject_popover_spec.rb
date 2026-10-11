# frozen_string_literal: true

require 'rails_helper'

# What: The two-column capture popover behind the hours sum in the ticket
#       header (doc/zeit_erfassen_an_der_summe_plan.md, designer handoff
#       "Uebergabe Tickets" §9). Form column only for writers; the review
#       column goes through the reader's OWN viewing scope, so it can never
#       show a session the chip's sum does not count; the drill-down into the
#       times list sits in the footer. The old billing-assignment popover and
#       its controller are gone.
# Type: Request spec against GET subject_popover (the chip's lazy frame src).
RSpec.describe 'Organisations::TimeSessions subject popover', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:member_role)  { create(:role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:member)       { create(:user) }
  let(:colleague)    { create(:user) }

  let(:project) { with_tenant { create(:project, organisation: organisation, name: 'Kesselhaus') } }
  let(:ticket)  { with_tenant { create(:ticket, project: project, creator: admin, title: 'Kessel flicken') } }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
      create(:membership, user: member, organisation: organisation, role: member_role, active: true)
      create(:membership, user: colleague, organisation: organisation, role: member_role, active: true)
    end
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def book(minutes, creator:, description: nil, group: nil, billed: false, at: Time.current)
    with_tenant do
      create(:time_session, project: project, organisation: organisation, creator: creator, ticket: ticket,
                            duration: minutes, description: description, time_session_group: group,
                            billed: billed, occurred_on: at)
    end
  end

  def fetch_popover
    get subject_popover_organisation_time_sessions_path(organisation, ticket_id: ticket.id, project_id: project.id)
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def row_texts
    doc.css('li').map { |li| li.text.squish }
  end

  context 'as account admin' do
    before { sign_in admin }

    it 'answers inside the frame the chip requests, with form, rows newest first and the footer link' do
      group = with_tenant { create(:time_session_group, organisation: organisation, name: '05-2026-muster') }
      book(20, creator: admin, description: 'Farbreihenfolge geprüft', at: 1.day.ago)
      book(60, creator: colleague, description: 'Vergleich besprochen', group: group, at: 2.days.ago)
      book(28, creator: admin, description: 'Ticket aufgenommen', at: 1.hour.ago)

      fetch_popover
      expect(response).to have_http_status(:ok)

      expect(doc.at_css("turbo-frame#subject_time_popover_#{ticket.id}")).to be_present

      form = doc.at_css("form[action='#{organisation_time_sessions_path(organisation)}']")
      expect(form).to be_present
      expect(form.at_css("input[name='context']")&.[]('value')).to eq('subject_popover')
      expect(form.at_css("input[name='time_session[ticket_id]']")&.[]('value')).to eq(ticket.id)
      expect(form.at_css("input[name='time_session[project_id]']")&.[]('value')).to eq(project.id)
      # No subject select and no billing select — the click location answered
      # the subject, and assigning lives in the times list (handoff §9).
      expect(form.css('select')).to be_empty

      # Newest first: 1 hour ago, then yesterday, then two days ago.
      expect(row_texts.first).to include('Ticket aufgenommen')
      expect(row_texts.last).to include('Vergleich besprochen')
      # The state sits at the row: the billing name once assigned, "offen" otherwise.
      expect(row_texts.last).to include('05-2026-muster')
      expect(row_texts.first).to include(I18n.t('views.time_sessions.billing_status.without_billing'))

      # The sum and the per-bucket breakdown, in clock format. doc.text, not the
      # raw body: value and state word sit in separate nodes.
      expect(response.body).to include('1:48')
      expect(doc.text.squish).to include("0:48 h #{I18n.t('views.time_sessions.billing_status.without_billing')}")

      # Not the first a[href*=ticket_id]: since edit mode the ROWS carry links
      # with the same param. The footer link is the one onto the times list.
      footer_link = doc.css('a[href*="ticket_id="]').find do |link|
        URI.parse(CGI.unescapeHTML(link['href'])).path == organisation_time_sessions_path(organisation)
      end
      expect(footer_link).to be_present
      href = CGI.unescapeHTML(footer_link['href'])
      expect(href).to include('date_range=all')
    end

    # The review column is a preview beside the form, capped at 10 — the footer
    # link opens the full list. Boundary at n-1 / n / n+1.
    it 'lists at most 10 bookings, the newest ones' do
      [9, 10, 11].each_with_index do |count, round|
        with_tenant { ticket.time_sessions.delete_all }
        count.times { |i| book(10, creator: admin, description: "Buchung #{round}-#{i}", at: (count - i).days.ago) }

        fetch_popover
        expect(doc.css('li').size).to eq([count, 10].min)
        expect(row_texts.first).to include("Buchung #{round}-#{count - 1}")
        if count > 10
          # The oldest booking falls out, never a newer one.
          expect(response.body).not_to include("Buchung #{round}-0")
        end
      end
    end
  end

  context 'as someone who may only see their own hours' do
    before do
      with_tenant do
        create(:project_permission, user: member, project: project, tickets_access: 'read_only')
        create(:time_session_permission, user: member, project: project,
                                         can_view_own: true, can_view_all: false, can_create_own: false)
      end
      book(20, creator: member, description: 'Eigene Buchung')
      book(30, creator: colleague, description: 'Fremde Buchung')
      sign_in member
    end

    it 'shows only their own rows and their own sum, and no form without the booking right' do
      fetch_popover
      expect(response).to have_http_status(:ok)

      expect(response.body).to include('Eigene Buchung')
      expect(response.body).not_to include('Fremde Buchung')
      expect(response.body).to include('0:20')
      expect(response.body).to include(I18n.t('components.subject_time_summary.scope.own'))
      expect(doc.css('form')).to be_empty
    end
  end

  context 'as someone who may book but not view' do
    before do
      with_tenant do
        create(:project_permission, user: member, project: project, tickets_access: 'read_only')
        create(:time_session_permission, user: member, project: project,
                                         can_view_own: false, can_view_all: false, can_create_own: true)
      end
      book(30, creator: colleague, description: 'Fremde Buchung')
      sign_in member
    end

    # No visible booking means no review column at all (user, 05.09.2026): the
    # popover is just the form, and nothing of the foreign booking leaks.
    it 'shows only the form, without a review column' do
      fetch_popover
      expect(response).to have_http_status(:ok)

      expect(doc.css('form')).to be_present
      expect(response.body).not_to include('Fremde Buchung')
      expect(doc.css('li')).to be_empty
      expect(doc.css('a')).to be_empty
    end
  end

  context 'as someone who may not see the ticket' do
    before do
      book(30, creator: colleague, description: 'Fremde Buchung')
      sign_in member
    end

    it 'denies the popover' do
      fetch_popover
      expect(response).to have_http_status(:found)
      expect(response.body).not_to include('Fremde Buchung')
    end
  end

  context 'with a meeting subject' do
    let(:meeting) { with_tenant { create(:meeting, project: project, organisation: organisation, creator: admin) } }

    before { sign_in admin }

    it 'answers for the meeting, with the meeting bound in the form' do
      with_tenant do
        create(:time_session, project: project, organisation: organisation, creator: admin,
                              meeting: meeting, duration: 45, description: 'Besprochen')
      end

      get subject_popover_organisation_time_sessions_path(organisation, meeting_id: meeting.id, project_id: project.id)
      expect(response).to have_http_status(:ok)
      expect(doc.at_css("turbo-frame#subject_time_popover_#{meeting.id}")).to be_present
      form = doc.at_css('form')
      expect(form.at_css("input[name='time_session[meeting_id]']")&.[]('value')).to eq(meeting.id)
      expect(response.body).to include('Besprochen')
    end
  end

  it 'answers 404 without a subject' do
    sign_in admin
    get subject_popover_organisation_time_sessions_path(organisation, project_id: project.id)
    expect(response).to have_http_status(:not_found)
  end

  # Defense in depth: seeing the TICKET is not seeing its time. The area gate
  # must deny on its own, with the ticket gate already passed — remove it from
  # #subject_popover and this goes red while every other example stays green.
  context 'as someone who may read the ticket but holds no time-sessions right' do
    before do
      with_tenant do
        create(:project_permission, user: member, project: project, tickets_access: 'read_only')
        create(:time_session_permission, user: member, project: project,
                                         can_view_own: false, can_view_all: false, can_create_own: false)
      end
      book(30, creator: colleague, description: 'Fremde Buchung')
      sign_in member
    end

    it 'denies the popover' do
      fetch_popover
      expect(response).to have_http_status(:found)
      expect(response.body).not_to include('Fremde Buchung')
    end
  end

  # Cross-tenant: a foreign organisation's ticket id resolves through
  # @project.tickets and must land on 404, never on an empty popover.
  it 'answers 404 for a ticket of another organisation' do
    foreign_org = create(:organisation)
    foreign_ticket = ActsAsTenant.with_tenant(foreign_org) do
      foreign_project = create(:project, organisation: foreign_org)
      create(:ticket, project: foreign_project, creator: admin, title: 'Fremdes Ticket')
    end

    sign_in admin
    get subject_popover_organisation_time_sessions_path(
      organisation, ticket_id: foreign_ticket.id, project_id: project.id
    )
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include('Fremdes Ticket')
  end

  # The breakdown line iterates TimeSession::BILLING_STATUS_FILTERS. The
  # expectation map is matched against the constant FIRST, so both a shrunk and
  # a grown constant fail here instead of silently shrinking the loop.
  it 'names every non-empty bucket of the constant in the breakdown line' do
    sign_in admin
    open_group   = with_tenant { create(:time_session_group, organisation: organisation, name: '06-2026-muster') }
    billed_group = with_tenant { create(:time_session_group, :billed, organisation: organisation) }
    book(20, creator: admin)
    book(60, creator: admin, group: open_group)
    book(28, creator: admin, group: billed_group, billed: true)

    fetch_popover

    expected = { 'without_billing' => '0:20', 'in_billing' => '1:00', 'billed' => '0:28' }
    expect(expected.keys).to match_array(TimeSession::BILLING_STATUS_FILTERS)
    TimeSession::BILLING_STATUS_FILTERS.each do |bucket|
      label = I18n.t("views.time_sessions.billing_status.#{bucket}")
      expect(doc.text.squish).to include("#{expected.fetch(bucket)} h #{label}")
    end
  end

  # The date default is a contract, not a coincidence: the form must open on
  # today, so the fastest path (type duration, hit Eintragen) books correctly.
  it 'pre-fills the date field with today' do
    sign_in admin
    fetch_popover

    date_input = doc.at_css("input[name='time_session[occurred_on]']")
    expect(date_input['value']).to eq(Date.current.iso8601)
  end

  # A sum of one summand is no information (designer, 05.09.2026): with exactly
  # one booking the head says only "bisher erfasst" and the number appears
  # ONCE, in the row; the second booking brings the sum back because it then
  # summarises something. Boundary at 1 / 2. The empty description renders in
  # placeholder colour, so an empty field reads as empty.
  it 'drops the sum head for a single booking and brings it back with the second' do
    sign_in admin
    book(135, creator: admin, description: nil)

    fetch_popover
    expect(doc.text).to include(I18n.t('views.organisations.time_sessions.subject_popover.captured_single'))
    expect(doc.text.squish.scan('2:15').size).to eq(1)
    placeholder_text = I18n.t('views.organisations.time_sessions.subject_popover.no_description')
    placeholder = doc.css('span').find { |node| node.text.strip == placeholder_text }
    expect(placeholder).to be_present
    expect(placeholder['class']).to include('text-cream-500')

    book(30, creator: admin, description: 'Zweite Buchung')
    fetch_popover
    expect(doc.text).not_to include(I18n.t('views.organisations.time_sessions.subject_popover.captured_single'))
    expect(doc.text).to include('2:45')
  end
end
