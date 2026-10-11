# frozen_string_literal: true

require 'rails_helper'

# What: The concrete status values of one project in the time list's ticket
#       filter (step 3b of doc/zeiten_weitere_filter_plan.md, E3).
# Type: Request spec, Prosopite ON for the requests (see the phase spec next door).
# Why:  Once a project is chosen, the ticket filter offers that project's own
#       status values below the three phases. A phase and a value replace each
#       other, one pill shows whichever is set, and dropping the project drops
#       the value (a value belongs to a project) but keeps the phase.
#       A value is a statement about a ticket's status: it is offered, named and
#       matched only for tickets the reader may open. That half is the :ci_guard.
RSpec.describe 'Time list: the ticket status values of one project', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:member_role)  { create(:role, organisation: organisation) }
  let(:viewer)       { create(:user, first_name: 'Vera', last_name: 'Viewer') }

  let(:project_a) { with_tenant { create(:project, organisation: organisation, name: 'Alpha') } }
  let(:project_b) { with_tenant { create(:project, organisation: organisation, name: 'Beta') } }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause
    with_tenant do
      create(:membership, user: viewer, organisation: organisation, role: member_role, active: true)
      [project_a, project_b].each do |project|
        create(:time_session_permission, user: viewer, project: project, can_view_own: true, can_view_all: true)
        ProjectPermission.find_by!(user: viewer, project: project).update!(tickets_access: 'read_only')
      end
      status_definition(project_a, [['Offen', ['is_open'], 'Open'], ['Liegt', ['is_backlog'], 'Parked'],
                                    ['Fertig', ['is_completed'], 'Finished']])
      status_definition(project_b, [['Done', ['is_closed'], nil]])
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

  # An English label on some options and none on the last project's, so the
  # label is read per locale and the stored value stands in without one.
  def status_definition(project, values)
    allowed = values.map do |value, functions, english|
      option = { 'value' => value, 'system_functions' => functions }
      english ? option.merge('labels' => { 'de' => value, 'en' => english }) : option
    end
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
  def pill = doc.at_css('[data-filter-pill="ticket_phase"]')
  def project_pill = doc.at_css('[data-filter-pill="project"]')
  def option_names(scope) = scope.css('a[data-filter-pill-option]').map { |link| link.text.squish }
  def option_named(scope, name) = scope.css('a[data-filter-pill-option]').find { |link| link.text.squish == name }
  def heading(scope) = scope.at_css('[data-filter-option-heading]')
  def query_of(link) = Rack::Utils.parse_nested_query(URI.parse(link['href']).query)
  def owns_of(link) = JSON.parse(link['data-query-toggle-owns'])
  def phases = TimeSessions::TicketPhase::KEYS.map { |key| TimeSessions::TicketPhase.label(key) }
  def all_label = I18n.t('views.organisations.time_sessions.index.filter_all_ticket_phases')
  def bare_name = I18n.t('views.organisations.time_sessions.empty_reason.names.ticket_phase')

  def rows_shown
    ['Zeile erledigt A', 'Zeile offen A', 'Zeile im Backlog A', 'Zeile ohne Ticket', 'Zeile erledigt B']
      .select { |text| response.body.include?(text) }
  end

  describe 'the offer' do
    it 'offers only the phases while no project is chosen' do
      get_list
      panel

      expect(option_names(section)).to eq(phases)
      expect(heading(section)).to be_nil
    end

    it 'lists the chosen project\'s values below the phases, in their order, under the project\'s name' do
      get_list(project_id_filter: project_a.id)

      expect(option_names(section)).to eq(phases + %w[Offen Liegt Fertig])
      expect(heading(section).text.squish)
        .to eq(I18n.t('views.organisations.time_sessions.index.filter_ticket_status_heading', project: 'Alpha'))
      # One heading, right above the first value, not above the phases.
      expect(section.css('[data-filter-option-heading]').size).to eq(1)
      expect(heading(section).next_element.text.squish).to eq('Offen')
    end

    it 'prints each value in the reader\'s language, the stored value where there is no label' do
      get_list(project_id_filter: project_a.id, locale: 'en')
      expect(option_names(section).last(3)).to eq(%w[Open Parked Finished])

      get_list(project_id_filter: project_b.id, locale: 'en')
      expect(option_names(section).last).to eq('Done')
    end

    it 'offers no values for a project without a status field' do
      with_tenant { TicketAttributeDefinition.where(project: project_a).update_all(active: false) }

      get_list(project_id_filter: project_a.id)

      expect(option_names(section)).to eq(phases)
      expect(heading(section)).to be_nil
    end

    it 'makes a value replace the phase and keep the rest of the address' do
      get_list(project_id_filter: project_a.id, search: 'Zeile')

      link = option_named(section, 'Fertig')
      expect(query_of(link)).to include('ticket_status' => 'Fertig', 'project_id_filter' => project_a.id,
                                        'search' => 'Zeile', 'date_range' => 'all')
      expect(query_of(link)).not_to have_key('ticket_phase')
      expect(owns_of(link)).to include(%w[ticket_status Fertig], ['ticket_phase', ''])
    end

    it 'makes a phase replace the value' do
      get_list(project_id_filter: project_a.id, ticket_status: 'Fertig')

      link = option_named(pill, TimeSessions::TicketPhase.label('done'))
      expect(query_of(link)).to include('ticket_phase' => 'done')
      expect(query_of(link)).not_to have_key('ticket_status')
      expect(owns_of(link)).to include(['ticket_status', ''])
    end
  end

  describe 'a chosen value' do
    it 'finds exactly the bookings on tickets with that value' do
      get_list(project_id_filter: project_a.id, ticket_status: 'Fertig')

      expect(rows_shown).to eq(['Zeile erledigt A'])
    end

    # A value is matched exactly, like the ticket table's own status filter
    # (AdHocFilterService). Case folding differs between Ruby and Postgres
    # (LOWER leaves "Ü" alone under LC_CTYPE=C), and the menu offered
    # "Überprüfung" over a list the database had emptied (review of #936).
    it 'finds a value with a non-ASCII capital, chosen from the menu' do
      Prosopite.pause
      with_tenant do
        TicketAttributeDefinition.find_by!(project: project_a, name: 'status').tap do |definition|
          definition.update_column(:options, { 'allowed_values' => definition.allowed_values + [{ 'value' => 'Überprüfung' }] })
        end
        book(project_a, 'Zeile in Prüfung A', ticket_in(project_a, 'Überprüfung'))
      end
      Prosopite.resume

      get_list(project_id_filter: project_a.id)
      get option_named(section, 'Überprüfung')['href']
      expect(response).to have_http_status(:ok)

      expect(response.body).to include('Zeile in Prüfung A')
      expect(rows_shown).to be_empty
      expect(pill.at_css('summary').text.squish).to include('Ticket: Überprüfung')
    end

    # The API accepts an option value that is a JSON number, and a ticket
    # storing it. The menu offers it as "1"; containment asked for the string
    # "1" and found nothing (second review of #936). Matched as text now.
    it 'finds a value stored as a number, chosen from the menu' do
      Prosopite.pause
      with_tenant do
        TicketAttributeDefinition.find_by!(project: project_a, name: 'status').tap do |definition|
          definition.update_column(:options, { 'allowed_values' => definition.allowed_values + [{ 'value' => 1 }] })
        end
        book(project_a, 'Zeile Nummer A', ticket_in(project_a, 1))
      end
      Prosopite.resume

      get_list(project_id_filter: project_a.id)
      get option_named(section, '1')['href']
      expect(response).to have_http_status(:ok)

      expect(response.body).to include('Zeile Nummer A')
      expect(rows_shown).to be_empty
      expect(pill.at_css('summary').text.squish).to include('Ticket: 1')
    end

    # Exact, so the page and the query agree on a value in another case too:
    # neither finds it.
    it 'neither matches nor names a value typed in another case' do
      get_list(project_id_filter: project_a.id, ticket_status: 'fertig')

      expect(rows_shown).to be_empty
      expect(pill).to be_nil
    end

    it 'wears the pill of the ticket filter, with the value marked and a way back' do
      get_list(project_id_filter: project_a.id, ticket_status: 'Fertig')

      expect(pill['data-filter-pill-state']).to eq('set')
      expect(pill.at_css('summary').text.squish).to include('Ticket: Fertig')
      expect(section).to be_nil

      links = pill.css('a[data-filter-pill-option]')
      expect(links.select { |link| link['aria-current'] == 'true' }.map { |link| link.text.squish }).to eq(['Fertig'])
      expect(links.first.text.squish).to eq(all_label)
      expect(query_of(links.first)).not_to have_key('ticket_status')

      clear = pill.at_css('summary a[data-query-toggle-owns]')
      expect(query_of(clear)).not_to have_key('ticket_status')
      expect(owns_of(clear)).to include(['ticket_status', ''], ['ticket_phase', ''])
    end

    it 'goes with the project, while a phase stays' do
      get_list(project_id_filter: project_a.id, ticket_status: 'Fertig')
      expect(query_of(project_pill.at_css('summary a[data-query-toggle-owns]'))).not_to have_key('ticket_status')
      expect(query_of(option_named(project_pill, 'Beta'))).not_to have_key('ticket_status')

      get_list(project_id_filter: project_a.id, ticket_phase: 'done')
      expect(query_of(project_pill.at_css('summary a[data-query-toggle-owns]'))).to include('ticket_phase' => 'done')
    end

    it 'carries the value across a submit of the filter form' do
      get_list(project_id_filter: project_a.id, ticket_status: 'Fertig')

      expect(doc.at_css('input[type="hidden"][data-filter-state="ticket_status"]')['value']).to eq('Fertig')
    end

    it 'counts once on the badge, like the phase it replaces' do
      neutral = { status_filters: TimeSession::BILLING_STATUS_FILTERS, project_id_filter: project_a.id }

      get_list(**neutral)
      without = doc.at_css('[data-filter-count]')['data-filter-count'].to_i

      get_list(**neutral, ticket_status: 'Fertig')
      expect(doc.at_css('[data-filter-count]')['data-filter-count'].to_i).to eq(without + 1)
      expect(doc.at_css('#time_filter_reset a[data-filter-reset]')).to be_present
    end

    it 'names the value in the empty state, with a removal that brings rows back' do
      get_list(project_id_filter: project_a.id, ticket_status: 'Fertig', search: 'Zeile ohne Ticket')

      chip = doc.at_css('[data-empty-filter="ticket_phase"]')
      expect(chip.text.squish).to include('Ticket: Fertig')
      expect(query_of(chip)).not_to have_key('ticket_status')
    end
  end

  # D5: a value the menu does not offer names nothing. The list still filters
  # by it and finds what it finds.
  describe 'a typed value' do
    it 'filters without a project, but names nothing' do
      get_list(ticket_status: 'Done')
      panel

      expect(rows_shown).to eq(['Zeile erledigt B'])
      expect(pill).to be_nil
      expect(section).to be_present
    end

    it 'answers a value foreign to the chosen project with an empty list and the bare name' do
      get_list(project_id_filter: project_a.id, ticket_status: 'Done')
      panel

      expect(rows_shown).to be_empty
      expect(pill).to be_nil
      chip = doc.at_css('[data-empty-filter="ticket_phase"]').text.squish
      expect(chip).to include(bare_name)
      expect(chip).not_to include('Done')
    end

    it 'answers a value given as a list without an error' do
      get organisation_time_sessions_path(organisation, date_range: 'all', project_id_filter: project_a.id,
                                                        ticket_status: ['Fertig'])

      expect(response).to have_http_status(:ok)
      expect(pill).to be_nil
    end

    # A list is no value: the filter form must not turn it into one. Carried
    # as a hidden field it came back as value="Fertig", and the next submit
    # filtered by a value the page had not named (review of #936).
    it 'does not carry a value given as a list into the filter form' do
      get organisation_time_sessions_path(organisation, date_range: 'all', project_id_filter: project_a.id,
                                                        ticket_status: ['Fertig'], ticket_phase: ['done'])
      expect(response).to have_http_status(:ok)

      expect(doc.at_css('input[type="hidden"][data-filter-state="project_id_filter"]')['value']).to eq(project_a.id)
      expect(doc.at_css('input[type="hidden"][data-filter-state="ticket_status"]')).to be_nil
      expect(doc.at_css('input[type="hidden"][data-filter-state="ticket_phase"]')).to be_nil
    end
  end

  context 'when the reader may not open the tickets of the chosen project' do
    before { with_tenant { ProjectPermission.find_by!(user: viewer, project: project_b).update!(tickets_access: 'no_access') } }

    # The phases stay on offer: the reader opens tickets in Alpha.
    it 'offers none of its values and finds nothing with one' do
      get_list(project_id_filter: project_b.id)
      expect(option_names(section)).to eq(phases)
      expect(heading(section)).to be_nil

      get_list(project_id_filter: project_b.id, ticket_status: 'Done')
      expect(rows_shown).to be_empty
      expect(pill).to be_nil
    end

    it 'finds nothing there with a typed value either' do
      get_list(ticket_status: 'Done')

      expect(rows_shown).to be_empty
    end
  end
end
