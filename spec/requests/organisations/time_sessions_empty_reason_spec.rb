# frozen_string_literal: true

require 'rails_helper'

# What: The empty state of the time list names the filter that emptied it and
#       offers it for removal. S3 of doc/zeiten_filterzeile_und_stand_plan.md (F5).
# Type: Request spec over the rendered page, and then over the link it offers.
# Why:  "Deine Filter haben keine Treffer ergeben" was true of six filters at
#       once, two of which are DEFAULTS the reader never set (this month, billed
#       hidden). The page now makes a promise instead: take this one away and
#       rows come back. The oracle here is therefore not the sentence but the
#       LINK -- every example that reads a pill follows it and expects the list
#       to fill up. A pill that leads to another empty list is the failure this
#       file exists to catch.
RSpec.describe 'Time list: the empty state names the culprit', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:colleague)    { create(:user) }
  let(:project)      { with_tenant { create(:project, organisation: organisation, name: 'WebApp2') } }
  let(:other_project) { with_tenant { create(:project, organisation: organisation, name: 'Nebenprojekt') } }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
      create(:membership, user: colleague, organisation: organisation, role: create(:role, organisation: organisation),
                          active: true)
    end
    sign_in admin
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def book(state: 'without_billing', on: Date.current, project: self.project, creator: admin,
           group: nil, description: 'Arbeit', ticket: nil)
    with_tenant do
      attrs = { organisation: organisation, project: project, creator: creator, duration: 60,
                occurred_on: on, description: description, ticket: ticket }
      case state
      when 'billed'
        create(:time_session, **attrs, billed: true,
                                       time_session_group: group || create(:time_session_group, :billed, organisation: organisation))
      when 'in_billing'
        create(:time_session, **attrs, time_session_group: group || create(:time_session_group, organisation: organisation))
      else
        create(:time_session, **attrs)
      end
    end
  end

  def get_list(**params)
    get organisation_time_sessions_path(organisation, **params)
    expect(response).to have_http_status(:ok)
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  # The removal offers, read back as { filter key => [label, href] } from what a
  # reader sees.
  def offers(scope = doc)
    scope.css('a[data-empty-filter]').to_h do |link|
      [link['data-empty-filter'].to_sym, [link.text.strip.split("\n").first.to_s.strip, CGI.unescapeHTML(link['href'])]]
    end
  end

  def label_of(key)
    offers.fetch(key).first
  end

  def href_of(key)
    offers.fetch(key).second
  end

  def billing_word(state)
    I18n.t("views.time_sessions.billing_status.#{state}")
  end

  # Where the offers navigate. The pills sit inside time_sessions_list_frame and
  # the filter row outside it, so every offer has to leave the frame, or the
  # removed filter stays standing in the row above the list.
  def frame_targets
    doc.css('a[data-empty-filter], a[data-empty-reset]').map { |link| link['data-turbo-frame'] }
  end

  def reset_href
    link = doc.at_css('a[data-empty-reset]')
    expect(link).to be_present
    CGI.unescapeHTML(link['href'])
  end

  # How many ROWS the list shows (one subject in one month). Anchored on the
  # group key every row carries, NOT on data-time-session-id: that one sits on
  # the edit button, which a billed booking does not get, so it would count a
  # billed list as empty.
  def rows_in_body
    doc.css('#time_sessions_body [data-ticket-group-key-value]').size
  end

  describe 'a list emptied by ONE filter' do
    it 'names the period and the link it offers actually fills the list' do
      book(on: 2.months.ago)

      get_list

      expect(offers.keys).to eq([:period])
      expect(label_of(:period)).to include('Zeitraum')
      # The sentence for ONE culprit, by its own key: an assertion through
      # t(count: 1) would follow a swapped one/other pair and stay green. No
      # reset beside a pill, and every offer leaves the frame.
      expect(response.body).to include(I18n.t('views.organisations.time_sessions.empty_reason.culprits.one'))
      expect(doc.css('a[data-empty-reset]')).to be_empty
      expect(frame_targets).to all(eq('_top'))

      get href_of(:period)
      expect(response).to have_http_status(:ok)
      expect(rows_in_body).to be_positive
    end

    it 'names the status when everything in the period is already billed' do
      book(state: 'billed')

      get_list

      expect(offers.keys).to eq([:status])
      # The states that are ON, in the canonical order (the defaults arrive as
      # in_billing, without_billing), each through the one word helper (S1).
      expect(label_of(:status)).to eq("Status: #{billing_word('without_billing')}, #{billing_word('in_billing')}")

      get href_of(:status)
      expect(response).to have_http_status(:ok)
      expect(rows_in_body).to be_positive
    end

    it 'names a single state by its word' do
      book

      get_list(status_filters: %w[billed])

      expect(offers.keys).to eq([:status])
      expect(label_of(:status)).to eq("Status: #{billing_word('billed')}")
    end

    it 'switches all three states on rather than clearing the parameter' do
      # An absent status_filters is not "all three", it is the default that hides
      # billed. Clearing it would leave the filter that emptied the list in place.
      book(state: 'billed')

      get_list(billing_status: 'unbilled')

      expect(offers.keys).to eq([:status])
      # The legacy param carries no list of states to print, so the pill is the
      # bare name. Pinned as the accepted fallback: nothing links here with it.
      expect(label_of(:status)).to eq('Status')

      href = href_of(:status)
      TimeSession::BILLING_STATUS_FILTERS.each { |state| expect(href).to include(state) }
      expect(href).not_to include('billing_status')
    end
  end

  describe 'a list emptied by a PAIR' do
    it 'offers both, in the order the filter row is read in' do
      book(on: 2.months.ago)   # outside the period, inside the status
      book(state: 'billed')    # inside the period, outside the status

      get_list

      expect(offers.keys).to eq(%i[period status])
      expect(response.body).to include(I18n.t('views.organisations.time_sessions.empty_reason.culprits.other'))
      expect(response.body).not_to include(I18n.t('views.organisations.time_sessions.empty_reason.culprits.one'))
      expect(doc.css('a[data-empty-reset]')).to be_empty
    end

    it 'names the subject and the billing with their own names' do
      ticket = with_tenant { create(:ticket, organisation: organisation, project: project, title: 'Kessel flicken') }
      group  = with_tenant { create(:time_session_group, organisation: organisation, name: 'August 2026') }
      book(ticket: ticket)
      book(state: 'in_billing', group: group)

      get_list(ticket_id: ticket.id, time_session_group_id: group.id, date_range: 'all',
               status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(offers.keys).to eq(%i[subject billing])
      expect(label_of(:subject)).to include("##{ticket.number}", 'Kessel flicken')
      expect(label_of(:billing)).to include('August 2026')
    end
  end

  describe 'the values in the labels' do
    it 'spells the period out in dates, with the year on both bounds' do
      book(on: Date.new(2026, 8, 15))

      get_list(start_date: '2026-09-01', end_date: '2026-09-30')

      expect(label_of(:period)).to include('01.09.2026', '30.09.2026')
    end

    it 'prints a single bound as "ab" or "bis", and drops a bound it cannot use' do
      book(on: Date.new(2026, 8, 15))

      get_list(end_date: '2026-07-31', status_filters: TimeSession::BILLING_STATUS_FILTERS)
      expect(label_of(:period)).to eq('Zeitraum: bis 31.07.2026')

      get_list(start_date: '2026-09-01', status_filters: TimeSession::BILLING_STATUS_FILTERS)
      expect(label_of(:period)).to eq('Zeitraum: ab 01.09.2026')

      # A bound the filter service cannot parse is dropped by it, and the label
      # says the same. Before, the raw parameter reached .to_date and answered
      # with a 500 (Date::Error), an array (start_date[]=) with another
      # (NoMethodError). ONE owner for a typed bound: TimeSessions::DateBound.
      get_list(start_date: 'gestern', end_date: '2026-07-31', status_filters: TimeSession::BILLING_STATUS_FILTERS)
      expect(label_of(:period)).to eq('Zeitraum: bis 31.07.2026')

      get_list(start_date: ['x'], end_date: '2026-07-31', status_filters: TimeSession::BILLING_STATUS_FILTERS)
      expect(label_of(:period)).to eq('Zeitraum: bis 31.07.2026')

      get href_of(:period)
      expect(rows_in_body).to be_positive
    end

    it 'names the project and takes the subject with it when the project goes' do
      # A subject left over from ANOTHER project, which is the state the project
      # cascade exists to prevent: the two together match nothing, and only the
      # project can go, because the subject is where the hours are.
      #
      # Removing the project has to clear the subject WITH it. The subject select
      # is only rendered while a project is chosen, so a ticket_id left behind
      # would go on filtering the list from a control nobody can see.
      ticket = with_tenant { create(:ticket, organisation: organisation, project: other_project, title: 'Kessel flicken') }
      book(project: other_project, ticket: ticket)

      get_list(project_id_filter: project.id, ticket_id: ticket.id, date_range: 'all',
               status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(offers.keys).to eq([:project])
      expect(label_of(:project)).to include('WebApp2')
      expect(href_of(:project)).not_to include('project_id_filter')
      expect(href_of(:project)).not_to include('ticket_id')

      get href_of(:project)
      expect(rows_in_body).to be_positive
    end

    it 'names the search term and the creator toggle' do
      book(creator: colleague, description: 'Kesselhaus gestrichen') # the word, the wrong person
      book(creator: admin, description: 'Etwas ganz anderes')        # the person, not the word

      get_list(search: 'Kesselhaus', creator_id: admin.id, date_range: 'all',
               status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(offers.keys).to eq(%i[creator search])

      expect(label_of(:search)).to include('Kesselhaus')
      # "Nur meine Zeiten" has no value to print, so it stays the bare name.
      expect(label_of(:creator)).to eq('Nur meine Zeiten')
    end

    it "does not call a colleague's times 'meine'" do
      # creator_id is typeable, and the assistant's report links here with a
      # colleague's id. Nobody's name is printed for it: resolving a typed id
      # to a person would make the pill a lookup service.
      book(creator: admin)

      get_list(creator_id: colleague.id, date_range: 'all', status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(offers.keys).to eq([:creator])
      expect(label_of(:creator)).to eq(I18n.t('views.organisations.time_sessions.empty_reason.creator_other'))
    end

    it 'falls back to the bare name for a record it cannot read' do
      book

      get_list(ticket_id: SecureRandom.uuid, date_range: 'all',
               status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(label_of(:subject)).to eq('Bezug')
    end
  end

  describe 'when no single filter explains it' do
    it 'says so and offers a reset instead of a pill that would not help' do
      # One booking, old AND billed: dropping either filter alone leaves the
      # other hiding it.
      book(state: 'billed', on: 2.months.ago)

      get_list

      expect(offers).to be_empty
      expect(response.body).to include(
        I18n.t('views.organisations.time_sessions.empty_reason.none_alone')
      )
      expect(frame_targets).to all(eq('_top'))

      # The reset is a promise too, and the same oracle applies: follow it and
      # expect rows. The bare list address would re-apply the two defaults and
      # land on this very page again (Zweitreview of S3).
      get reset_href
      expect(response).to have_http_status(:ok)
      expect(rows_in_body).to be_positive
    end
  end

  describe 'whose names the pill may print' do
    let(:member_role) { create(:role, organisation: organisation) }
    let(:viewer)      { create(:user) }

    # A reader whose only right is a TimeSessionPermission, the shape
    # time_sessions_visibility_spec pins: no ProjectPermission, so no area.
    before do
      with_tenant do
        create(:membership, user: viewer, organisation: organisation, role: member_role, active: true)
        create(:time_session_permission, user: viewer, project: project, can_view_own: true, can_view_all: false)
        create(:time_session_permission, user: viewer, project: other_project, can_view_own: true, can_view_all: false)
      end
      sign_in viewer
    end

    it 'prints the project the reader sees time in, area rights or not' do
      # The project select offered it by name (viewing scope); the pill has to
      # say the same name. ProjectPolicy::Scope asks about the other areas and
      # answered this reader with the bare word.
      book(project: other_project, creator: viewer)

      get_list(project_id_filter: project.id, date_range: 'all', status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(offers.keys).to eq([:project])
      expect(label_of(:project)).to eq('Projekt: WebApp2')
    end

    it 'withholds a ticket title behind the tickets area' do
      # The subject select is gated by the tickets area, so a ticket this reader
      # could not have chosen there is not named for them either; the filter is
      # still offered for removal.
      secret = with_tenant do
        create(:ticket, organisation: organisation, project: other_project, title: 'Geheimes Vorhaben')
      end
      book(creator: viewer)

      get_list(ticket_id: secret.id, date_range: 'all', status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(offers.keys).to eq([:subject])
      expect(label_of(:subject)).to eq('Bezug')
      expect(response.body).not_to include('Geheimes Vorhaben')
    end
  end

  describe 'inside a smart folder that matches nothing' do
    it 'offers the reset, which drops the folder with the filters' do
      # The folder is the base query, not one of the removable filters: with
      # neutral filters nothing is active, no pill can help, and the generic
      # sentence alone would leave the reader without a way out of the folder.
      folder = with_tenant do
        f = create(:smart_folder, organisation: organisation, user: admin, project: nil, target_object_type: 'TimeSession')
        group = create(:smart_folder_rule_group, smart_folder: f, position: 1)
        create(:smart_folder_rule, smart_folder_rule_group: group, position: 1,
                                   field: 'duration', operator: 'greater_than', value: '100000')
        f
      end
      book

      get_list(smart_folder_id: folder.id, date_range: 'all', status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(offers).to be_empty
      expect(response.body).to include(
        I18n.t('views.organisations.time_sessions.index_table.empty_no_results_description')
      )

      get reset_href
      expect(response).to have_http_status(:ok)
      expect(rows_in_body).to be_positive
    end
  end

  describe 'what it leaves alone' do
    it 'keeps the first-use explainer for someone who has booked nothing at all' do
      get_list

      expect(offers).to be_empty
      expect(response.body).to include(
        I18n.t('views.organisations.time_sessions.index_table.empty_first_time_title')
      )
    end

    it 'shows the plain card and no explainer once anything has been booked' do
      # The other direction of the same branch: an explainer there would lecture
      # someone who already uses the area. Guarded over HTTP because "first use"
      # is a controller question about what THIS reader may see, and a view spec
      # can only answer it by stubbing the very predicate under test.
      book(on: 2.months.ago)

      get_list

      expect(response.body).not_to include(
        I18n.t('views.organisations.time_sessions.index_table.explainer.title')
      )
      expect(offers.keys).to eq([:period])
    end

    it 'asks the database nothing on the first-use page' do
      # The explainer wins in the view whatever the diagnosis says, so this is
      # not about what is rendered but about what it COSTS: up to seven EXISTS
      # for a page that cannot show a single one of their answers. Without this
      # example the guard in the controller is invisible to the suite, which is
      # how a cost-only guard gets deleted by the next reader.
      expect(TimeSessions::EmptyReason).not_to receive(:call)

      get_list
    end

    it 'says nothing when the list has rows' do
      book

      get_list

      expect(offers).to be_empty
      expect(rows_in_body).to be_positive
    end
  end

  describe 'inside the frame' do
    it 'travels with a frame answer, so a filter typed into the list can be undone there' do
      book(on: 2.months.ago)

      get organisation_time_sessions_path(organisation), headers: { 'Turbo-Frame' => 'time_sessions_list_frame' }

      expect(response).to have_http_status(:ok)
      expect(offers.keys).to eq([:period])
      expect(frame_targets).to all(eq('_top'))
    end
  end
end
