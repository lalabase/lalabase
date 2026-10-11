# frozen_string_literal: true

require 'rails_helper'

# What: The tag filter of the time list, offered under "+ Filter" (step 2 of
#       doc/zeiten_weitere_filter_plan.md, variant C: the tag on the booking OR
#       on its ticket).
# Type: Request spec. The menu is a <details> inside a <details>, so everything
#       asserted here is decided in Ruby.
# Why:  The menu lists tags of bookings the reader may see and of their tickets.
#       A tag used only where the reader sees nothing, or in another
#       organisation, is no filter that could find anything here, and the name
#       of a tag is only printed when the menu offers it (as with the person).
RSpec.describe 'Time list: the tag filter', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:member_role)  { create(:role, organisation: organisation) }
  let(:viewer)       { create(:user, first_name: 'Vera', last_name: 'Viewer') }

  let(:project_a) { with_tenant { create(:project, organisation: organisation, name: 'Sichtbar') } }
  let(:project_b) { with_tenant { create(:project, organisation: organisation, name: 'Geschlossen') } }
  let(:ticket)    { with_tenant { create(:ticket, project: project_a, organisation: organisation, title: 'Login kaputt') } }

  let(:own_tagged) { book(project_a, 'Zeile mit Tag an der Zeit', tags: 'kunde-a') }
  let(:on_ticket)  { book(project_a, 'Zeile am Ticket mit Tag', ticket: ticket) }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause
    with_tenant do
      create(:membership, user: viewer, organisation: organisation, role: member_role, active: true)
      create(:time_session_permission, user: viewer, project: project_a, can_view_own: true, can_view_all: true)
      ticket.update!(tag_list: 'bug')
    end
    own_tagged
    on_ticket
    book(project_a, 'Zeile ohne Tag')
    book(project_b, 'Zeile im geschlossenen Projekt', tags: 'geheimtag')
    sign_in viewer
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def book(project, description, ticket: nil, tags: nil)
    with_tenant do
      session = create(:time_session, organisation: organisation, project: project, creator: viewer,
                                      ticket: ticket, duration: 60, occurred_on: Date.current,
                                      description: description)
      session.update!(tag_list: tags) if tags
      session
    end
  end

  def tag_named(name) = with_tenant { Tag.find_by!(name: name) }

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

  def add_section(kind) = doc.at_css(%([data-filter-add="add"] [data-filter-add-section="#{kind}"]))
  def tag_pill = doc.at_css('[data-filter-pill="tag"]')
  def option_names(scope) = scope.css('a[data-filter-pill-option]').map { |link| link.text.squish }
  def query_of(link) = Rack::Utils.parse_nested_query(URI.parse(link['href']).query)
  def summary = doc.at_css('[data-result-summary]').text.squish

  it 'offers the tags of visible bookings and of their tickets, and nothing else' do
    with_tenant { create(:note, project: project_a, organisation: organisation, tag_list: 'nur-notiz') }
    get_list
    panel

    expect(option_names(add_section('tag'))).to eq(%w[bug kunde-a])
    expect(response.body).not_to include('geheimtag', 'nur-notiz')
  end

  # The other side of the isolation: a reader who may see everyone's time in a
  # project gets a colleague's tags too. The menu is built from the rows the
  # reader sees, not from the reader's own bookings. The tag is created last
  # and sorts first, so the order is by name and not by age.
  it 'offers the tags of a colleague\'s visible time, sorted by name' do
    with_tenant do
      colleague = create(:user)
      create(:membership, user: colleague, organisation: organisation, role: member_role, active: true)
      create(:time_session, organisation: organisation, project: project_a, creator: colleague,
                            duration: 30, occurred_on: Date.current, tag_list: 'aaa-kollegin')
    end

    get_list

    expect(option_names(add_section('tag'))).to eq(%w[aaa-kollegin bug kunde-a])
  end

  # The status pills count under every filter but the status (F4 of the filter
  # line plan). The tag reaches them through ListFilters, and this is where a
  # count built past the declaration would show: three hours beside a list of one.
  it 'counts the status pills under the tag' do
    none_box = ->(value) { doc.at_css(%([data-status-box="#{value}"])).text }

    get_list
    expect(none_box.call('without_billing')).to include(TimeSession.format_duration(180))

    get_list(tag_id: tag_named('bug').id)
    expect(none_box.call('without_billing')).to include(TimeSession.format_duration(60))
  end

  it 'lists the bookings carrying the tag themselves or through their ticket' do
    get_list(tag_id: tag_named('bug').id)

    expect(response.body).to include('Zeile am Ticket mit Tag')
    expect(response.body).not_to include('Zeile mit Tag an der Zeit', 'Zeile ohne Tag')

    get_list(tag_id: tag_named('kunde-a').id)

    expect(response.body).to include('Zeile mit Tag an der Zeit')
    expect(response.body).not_to include('Zeile am Ticket mit Tag', 'Zeile ohne Tag')
  end

  # Tagged on both sides, the booking is one booking: one in the count, its
  # minutes once in the sum.
  it 'counts a booking tagged on both sides once' do
    with_tenant { on_ticket.update!(tag_list: 'bug') }

    get_list(tag_id: tag_named('bug').id)

    expect(summary).to eq(
      I18n.t('views.organisations.time_sessions.index.result_summary',
             count: I18n.t('views.organisations.time_sessions.index.result_times', count: 1),
             duration: TimeSession.format_duration(60))
    )
  end

  it 'gives a chosen tag a pill of its own, with a way back' do
    get_list(tag_id: tag_named('bug').id)

    expect(tag_pill['data-filter-pill-state']).to eq('set')
    expect(tag_pill.at_css('summary').text.squish).to include('Tag: bug')
    expect(add_section('tag')).to be_nil

    links = tag_pill.css('a[data-filter-pill-option]')
    expect(links.select { |link| link['aria-current'] == 'true' }.map { |link| link.text.squish }).to eq(['bug'])
    expect(query_of(links.first)).not_to have_key('tag_id')

    clear = tag_pill.at_css('summary a[data-query-toggle-owns]')
    expect(query_of(clear)).not_to have_key('tag_id')
    expect(JSON.parse(clear['data-query-toggle-owns'])).to include(['tag_id', ''])
  end

  it 'keeps the filters already set when a tag is chosen' do
    get_list(project_id_filter: project_a.id, search: 'Zeile')

    link = add_section('tag').css('a[data-filter-pill-option]').find { |a| a.text.squish == 'bug' }
    expect(query_of(link)).to include('tag_id' => tag_named('bug').id, 'project_id_filter' => project_a.id,
                                      'search' => 'Zeile', 'date_range' => 'all')
  end

  it 'combines with the person filter' do
    colleague = create(:user, first_name: 'Anna', last_name: 'Aufwand')
    with_tenant do
      create(:membership, user: colleague, organisation: organisation, role: member_role, active: true)
      create(:time_session, organisation: organisation, project: project_a, creator: colleague, ticket: ticket,
                            duration: 30, occurred_on: Date.current, description: 'Annas Zeile am Ticket')
    end

    get_list(tag_id: tag_named('bug').id, creator_id: colleague.id)

    expect(response.body).to include('Annas Zeile am Ticket')
    expect(response.body).not_to include('Zeile am Ticket mit Tag')
    expect(doc.at_css('[data-filter-pill="person"]')).to be_present
    expect(tag_pill).to be_present
  end

  it 'recognises a tag id in capitals, as the list does' do
    get_list(tag_id: tag_named('bug').id.upcase)

    expect(response.body).to include('Zeile am Ticket mit Tag')
    expect(tag_pill.at_css('summary').text.squish).to include('Tag: bug')
  end

  it 'carries the chosen tag across a submit of the filter form' do
    get_list(tag_id: tag_named('bug').id)

    field = doc.at_css('input[type="hidden"][data-filter-state="tag_id"]')
    expect(field['value']).to eq(tag_named('bug').id)
  end

  it 'counts on the badge and brings the reset' do
    neutral = { status_filters: TimeSession::BILLING_STATUS_FILTERS }

    get_list(**neutral)
    without = doc.at_css('[data-filter-count]')['data-filter-count'].to_i
    expect(doc.at_css('#time_filter_reset a[data-filter-reset]')).to be_nil

    get_list(**neutral, tag_id: tag_named('bug').id)
    expect(doc.at_css('[data-filter-count]')['data-filter-count'].to_i).to eq(without + 1)
    expect(doc.at_css('#time_filter_reset a[data-filter-reset]')).to be_present
  end

  it 'names the tag in the empty state, with a removal that brings rows back' do
    get_list(tag_id: tag_named('bug').id, search: 'Zeile ohne Tag')

    chip = doc.at_css('[data-empty-filter="tag"]')
    expect(chip.text.squish).to include('Tag: bug')
    expect(query_of(chip)).not_to have_key('tag_id')
  end

  # D5 for tags: a name is printed only for a tag the menu offers.
  it 'names no tag the reader could not find anything with' do
    get_list(tag_id: tag_named('geheimtag').id)
    panel

    expect(tag_pill).to be_nil
    expect(response.body).not_to include('geheimtag', 'Zeile im geschlossenen Projekt')
  end

  it 'answers a junk id with an empty list, no name and no error' do
    get_list(tag_id: 'junk')
    panel

    expect(tag_pill).to be_nil
    expect(response.body).not_to include('Zeile mit Tag an der Zeit', 'Zeile am Ticket mit Tag', 'Zeile ohne Tag')
  end

  # The tenant boundary: another organisation's tags never reach the menu, and
  # its bookings never the list, whatever id is typed.
  context 'when another organisation tags its own bookings' do
    let(:foreign_org) { create(:organisation) }

    it 'never offers or names its tags' do
      foreign_tag = ActsAsTenant.with_tenant(foreign_org) do
        foreign_project = create(:project, organisation: foreign_org)
        foreign = create(:time_session, organisation: foreign_org, project: foreign_project, creator: create(:user),
                                        duration: 60, occurred_on: Date.current, description: 'Fremde Firma')
        foreign.update!(tag_list: 'fremdtag')
        Tag.find_by!(name: 'fremdtag')
      end

      get_list
      expect(option_names(add_section('tag'))).to eq(%w[bug kunde-a])

      get_list(tag_id: foreign_tag.id)
      panel
      expect(tag_pill).to be_nil
      expect(response.body).not_to include('fremdtag', 'Fremde Firma')
    end
  end

  # A deleted booking is no booking: the list does not show it, so neither its
  # own tag nor the tag of its ticket may reach the menu (second review).
  it 'offers no tag that only a deleted booking carries' do
    with_tenant do
      gone_ticket = create(:ticket, project: project_a, organisation: organisation, tag_list: 'nur-geloescht-ticket')
      book(project_a, 'Geloeschte Zeile', ticket: gone_ticket, tags: 'nur-geloescht-zeit')
        .update_column(:deleted_at, Time.current)
    end

    get_list
    expect(option_names(add_section('tag'))).to eq(%w[bug kunde-a])

    get_list(tag_id: tag_named('nur-geloescht-zeit').id)
    panel
    expect(tag_pill).to be_nil
    expect(response.body).not_to include('nur-geloescht')
  end

  # D3 for tags: "+ Filter" stands while it has anything to offer. A reader who
  # sees only their own time has no person to choose, but may have tags.
  context 'when the reader sees only their own time' do
    before do
      with_tenant do
        TimeSessionPermission.find_by!(user: viewer, project: project_a).update!(can_view_all: false)
        # A colleague in the SAME project, tagged on the booking and on the
        # ticket. The project is visible, the colleague's time is not: the menu
        # is built from rows, never from projects (second review).
        colleague = create(:user)
        create(:membership, user: colleague, organisation: organisation, role: member_role, active: true)
        foreign_ticket = create(:ticket, project: project_a, organisation: organisation,
                                         tag_list: 'kollegen-ticket')
        create(:time_session, organisation: organisation, project: project_a, creator: colleague,
                              ticket: foreign_ticket, duration: 60, occurred_on: Date.current,
                              description: 'Zeile der Kollegin', tag_list: 'kollegen-zeit')
      end
    end

    it 'offers the tags alone, and only those of the own time' do
      get_list
      panel

      expect(add_section('person')).to be_nil
      expect(option_names(add_section('tag'))).to eq(%w[bug kunde-a])
      expect(response.body).not_to include('kollegen-ticket', 'kollegen-zeit')
    end

    it 'names no tag of a colleague\'s time' do
      %w[kollegen-ticket kollegen-zeit].each do |name|
        get_list(tag_id: tag_named(name).id)
        panel

        expect(tag_pill).to be_nil
        expect(response.body).not_to include(name, 'Zeile der Kollegin')
      end
    end
  end

  context 'when no visible booking carries a tag' do
    before do
      with_tenant do
        [own_tagged, on_ticket].each { |session| session.update!(tag_list: '') }
        ticket.update!(tag_list: '')
      end
    end

    it 'offers no tag section' do
      get_list
      panel

      expect(add_section('tag')).to be_nil
    end
  end
end
