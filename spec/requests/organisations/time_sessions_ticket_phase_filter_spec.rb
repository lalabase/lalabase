# frozen_string_literal: true

require 'rails_helper'

# What: The ticket phase filter of the time list, under "+ Filter" (step 3a of
#       doc/zeiten_weitere_filter_plan.md, E1 to E6).
# Type: Request spec. Prosopite stays ON here on purpose: the phase reads the
#       status definitions per filter-service call, and a render that repeated
#       that per row would show up as an N+1.
# Why:  The phases (in backlog, in progress, done) come from the status System
#       Functions, so "done" finds "Fertig" in one project and "Done" in
#       another. A booking without a ticket has no phase and drops out.
#       A phase is a statement about a ticket's status, so it only ever reads
#       tickets the reader may open (TicketPolicy::Scope): seeing one's own time
#       on a ticket is not the right to see that ticket (review, 29.09.2026).
#       That half is the :ci_guard.
RSpec.describe 'Time list: the ticket phase filter', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:member_role)  { create(:role, organisation: organisation) }
  let(:viewer)       { create(:user, first_name: 'Vera', last_name: 'Viewer') }

  let(:project_a) { with_tenant { create(:project, organisation: organisation, name: 'Alpha') } }
  let(:project_b) { with_tenant { create(:project, organisation: organisation, name: 'Beta') } }

  # Prosopite is paused for the SETUP only: granting two permissions in a loop
  # reads ProjectPermission.archived_for twice, which it would report. The
  # requests below run with it on.
  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause
    with_tenant do
      create(:membership, user: viewer, organisation: organisation, role: member_role, active: true)
      [project_a, project_b].each do |project|
        create(:time_session_permission, user: viewer, project: project, can_view_own: true, can_view_all: true)
        # The time permission is backed by a project permission (the factory
        # makes one); the tickets area is opened on it.
        ProjectPermission.find_by!(user: viewer, project: project).update!(tickets_access: 'read_only')
      end
      status_definition(project_a, [['Offen', ['is_open']], ['Liegt', ['is_backlog']], ['Fertig', ['is_completed']]])
      status_definition(project_b, [['Done', ['is_closed']]])
      book(project_a, 'Zeile erledigt A', ticket_in(project_a, 'Fertig'))
      book(project_a, 'Zeile offen A', ticket_in(project_a, 'Offen'))
      book(project_a, 'Zeile im Backlog A', ticket_in(project_a, 'Liegt'))
      book(project_a, 'Zeile ohne Ticket')
      book(project_b, 'Zeile erledigt B', ticket_in(project_b, 'Done'))
    end
    sign_in viewer
    Prosopite.resume
  end

  after { ActsAsTenant.current_tenant = nil }

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def status_definition(project, values)
    allowed = values.map { |value, functions| { 'value' => value, 'system_functions' => functions } }
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                         options: { 'allowed_values' => allowed })
  end

  def ticket_in(project, status)
    create(:ticket, project: project, organisation: organisation).tap do |record|
      record.update_column(:custom_attributes, { 'status' => status })
    end
  end

  def book(project, description, ticket = nil)
    create(:time_session, organisation: organisation, project: project, creator: viewer, ticket: ticket,
                          duration: 60, occurred_on: Date.current, description: description)
  end

  def get_list(**params)
    get organisation_time_sessions_path(organisation, date_range: 'all', **params)
    expect(response).to have_http_status(:ok)
  end

  def doc = Nokogiri::HTML(response.body)

  # Proven present before anything is claimed absent from it.
  def panel
    node = doc.at_css('[data-filter-pill="period"]')
    expect(node).to be_present
    node
  end

  def section = doc.at_css('[data-filter-add="add"] [data-filter-add-section="ticket_phase"]')
  def phase_pill = doc.at_css('[data-filter-pill="ticket_phase"]')
  def option_names(scope) = scope.css('a[data-filter-pill-option]').map { |link| link.text.squish }
  def query_of(link) = Rack::Utils.parse_nested_query(URI.parse(link['href']).query)
  def summary = doc.at_css('[data-result-summary]').text.squish
  def label(key) = I18n.t("views.organisations.time_sessions.index.ticket_phase_#{key}")

  def rows_shown
    ['Zeile erledigt A', 'Zeile offen A', 'Zeile im Backlog A', 'Zeile ohne Ticket', 'Zeile erledigt B']
      .select { |text| response.body.include?(text) }
  end

  it 'offers the three phases, in a ticket\'s order, and says what drops out' do
    get_list
    panel

    expect(option_names(section)).to eq(TimeSessions::TicketPhase::KEYS.map { |key| label(key) })
    expect(section.at_css('[data-filter-add-notice]').text.squish)
      .to eq(I18n.t('views.organisations.time_sessions.index.filter_ticket_phase_notice'))
    # Three entries need no search field.
    expect(section.at_css('input[data-filter-menu-search-target="query"]')).to be_nil
  end

  # "Fertig" in one project, "Done" in the other: both are done.
  it 'finds the done bookings of every project by the meaning of their status' do
    get_list(ticket_phase: 'done')

    expect(rows_shown).to contain_exactly('Zeile erledigt A', 'Zeile erledigt B')
  end

  it 'finds work in progress without the bookings that have no ticket' do
    get_list(ticket_phase: 'active')

    expect(rows_shown).to eq(['Zeile offen A'])
  end

  it 'finds the backlog' do
    get_list(ticket_phase: 'backlog')

    expect(rows_shown).to eq(['Zeile im Backlog A'])
  end

  it 'narrows further with the project' do
    get_list(ticket_phase: 'done', project_id_filter: project_b.id)

    expect(rows_shown).to eq(['Zeile erledigt B'])
  end

  it 'sums only the bookings in the phase' do
    get_list(ticket_phase: 'done')

    expect(summary).to eq(
      I18n.t('views.organisations.time_sessions.index.result_summary',
             count: I18n.t('views.organisations.time_sessions.index.result_times', count: 2),
             duration: TimeSession.format_duration(120))
    )
    expect(doc.at_css('[data-status-box="without_billing"]').text).to include(TimeSession.format_duration(120))
  end

  it 'gives a chosen phase a pill of its own, with a way back' do
    get_list(ticket_phase: 'done')

    expect(phase_pill['data-filter-pill-state']).to eq('set')
    expect(phase_pill.at_css('summary').text.squish).to include("Ticket: #{label('done')}")
    expect(section).to be_nil

    links = phase_pill.css('a[data-filter-pill-option]')
    expect(links.select { |link| link['aria-current'] == 'true' }.map { |link| link.text.squish }).to eq([label('done')])
    expect(query_of(links.first)).not_to have_key('ticket_phase')

    clear = phase_pill.at_css('summary a[data-query-toggle-owns]')
    expect(query_of(clear)).not_to have_key('ticket_phase')
    expect(JSON.parse(clear['data-query-toggle-owns'])).to include(['ticket_phase', ''])
  end

  it 'keeps the filters already set when a phase is chosen' do
    get_list(project_id_filter: project_a.id, search: 'Zeile')

    link = section.css('a[data-filter-pill-option]').find { |a| a.text.squish == label('done') }
    expect(query_of(link)).to include('ticket_phase' => 'done', 'project_id_filter' => project_a.id,
                                      'search' => 'Zeile', 'date_range' => 'all')
  end

  it 'carries the chosen phase across a submit of the filter form' do
    get_list(ticket_phase: 'done')

    expect(doc.at_css('input[type="hidden"][data-filter-state="ticket_phase"]')['value']).to eq('done')
  end

  it 'counts on the badge and brings the reset' do
    neutral = { status_filters: TimeSession::BILLING_STATUS_FILTERS }

    get_list(**neutral)
    without = doc.at_css('[data-filter-count]')['data-filter-count'].to_i
    expect(doc.at_css('#time_filter_reset a[data-filter-reset]')).to be_nil

    get_list(**neutral, ticket_phase: 'done')
    expect(doc.at_css('[data-filter-count]')['data-filter-count'].to_i).to eq(without + 1)
    expect(doc.at_css('#time_filter_reset a[data-filter-reset]')).to be_present
  end

  it 'names the phase in the empty state, with a removal that brings rows back' do
    get_list(ticket_phase: 'done', search: 'Zeile ohne Ticket')

    chip = doc.at_css('[data-empty-filter="ticket_phase"]')
    expect(chip.text.squish).to include("Ticket: #{label('done')}")
    expect(query_of(chip)).not_to have_key('ticket_phase')
  end

  # An unknown phase finds nothing and stays a filter: the list is empty, the
  # empty state offers to remove it by its bare name, the menu stays open to
  # pick a real one.
  it 'answers an unknown phase with an empty list, no label and a way out' do
    get_list(ticket_phase: 'fertig')
    panel

    expect(rows_shown).to be_empty
    expect(phase_pill).to be_nil
    expect(doc.at_css('[data-empty-filter="ticket_phase"]').text.squish)
      .to include(I18n.t('views.organisations.time_sessions.empty_reason.names.ticket_phase'))
    expect(section).to be_present
  end

  it 'answers a phase given as a list without an error' do
    get organisation_time_sessions_path(organisation, date_range: 'all', ticket_phase: ['done'])

    expect(response).to have_http_status(:ok)
    expect(phase_pill).to be_nil
  end

  # The review's case: the reader may see their time in a project but not its
  # tickets. The phase would answer "is this ticket done?" for a ticket they
  # cannot open, so those bookings drop out of every phase, like bookings
  # without a ticket.
  context 'when the reader may not open the tickets of one project' do
    before { with_tenant { ProjectPermission.find_by!(user: viewer, project: project_b).update!(tickets_access: 'no_access') } }

    it 'leaves that project\'s bookings out of every phase' do
      get_list(ticket_phase: 'done')
      expect(rows_shown).to eq(['Zeile erledigt A'])

      get_list(ticket_phase: 'active')
      expect(rows_shown).to eq(['Zeile offen A'])
    end

    it 'still lists those bookings without the filter' do
      get_list

      expect(rows_shown).to include('Zeile erledigt B')
    end
  end

  # An archived project closes its tickets to members (ProjectAccessService
  # reads archived_at) while their own time there stays readable. The phase
  # follows the ticket right, not the time right (second review).
  context 'when one project is archived' do
    before { with_tenant { project_b.update_column(:archived_at, Time.current) } }

    it 'leaves the archived project\'s bookings out of the phase' do
      get_list
      expect(rows_shown).to include('Zeile erledigt B')

      get_list(ticket_phase: 'done')
      expect(rows_shown).to eq(['Zeile erledigt A'])
    end
  end

  context 'when the reader may open no ticket at all' do
    before { with_tenant { ProjectPermission.where(user: viewer).update_all(tickets_access: 'no_access') } }

    it 'offers no ticket phase and finds nothing with one' do
      get_list
      panel
      expect(section).to be_nil

      get_list(ticket_phase: 'done')
      expect(rows_shown).to be_empty
    end
  end

  # E5: without a booking on a ticket every phase would answer empty.
  context 'when no visible booking is on a ticket' do
    before { with_tenant { TimeSession.where.not(ticket_id: nil).update_all(ticket_id: nil) } }

    it 'offers no ticket phase' do
      get_list
      panel

      expect(section).to be_nil
    end
  end

  # The phase narrows what the reader may see and nothing else: a colleague's
  # done booking stays out of a list that shows only the reader's own time.
  context 'when the reader sees only their own time' do
    before do
      Prosopite.pause
      with_tenant do
        TimeSessionPermission.where(user: viewer).update_all(can_view_all: false)
        colleague = create(:user)
        create(:membership, user: colleague, organisation: organisation, role: member_role, active: true)
        create(:time_session, organisation: organisation, project: project_a, creator: colleague,
                              ticket: ticket_in(project_a, 'Fertig'), duration: 60, occurred_on: Date.current,
                              description: 'Zeile der Kollegin')
      end
      Prosopite.resume
    end

    it 'offers the phase and finds only the own done bookings' do
      get_list(ticket_phase: 'done')

      expect(rows_shown).to contain_exactly('Zeile erledigt A', 'Zeile erledigt B')
      expect(response.body).not_to include('Zeile der Kollegin')
    end
  end
end
