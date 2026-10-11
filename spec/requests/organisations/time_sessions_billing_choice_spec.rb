# frozen_string_literal: true

require 'rails_helper'

# What: Picking a billing in the time list opens the period and the status, so
#       the billing's hours are really in the list. S4 of
#       doc/zeiten_filterzeile_und_stand_plan.md (finding F6, decision D2).
# Type: Request spec. The browser half is six lines of Stimulus over a tested
#       lib function (spec/javascript/lib/query_toggle.test.js); what lives here
#       is the RULE, which is Ruby: what the choice takes with it, and what the
#       list then shows.
# Why:  A billing is a bundle of hours from whenever they were booked. The list
#       opens on THIS MONTH with billed hours hidden, so picking a billing from
#       July in September answered with an empty list, and picking one whose
#       hours are billed did the same. Two filters were hiding it and the page
#       named neither.
#
#       The oracle is not the data attribute but the ADDRESS it describes: every
#       example that reads the declaration follows it the way the browser would
#       (#address_for_choosing mirrors lib/query_toggle.js) and expects the
#       billing's every hour to be there.
RSpec.describe 'Time list: choosing a billing opens the filters', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:project)      { with_tenant { create(:project, organisation: organisation, name: 'WebApp2') } }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant { create(:membership, user: admin, organisation: organisation, role: admin_role, active: true) }
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

  def book(group:, on: Date.current, billed: false, minutes: 60)
    with_tenant do
      create(:time_session, organisation: organisation, project: project, creator: admin,
                            duration: minutes, occurred_on: on, billed: billed, time_session_group: group)
    end
  end

  def get_list(**params)
    get organisation_time_sessions_path(organisation, **params)
    expect(response).to have_http_status(:ok)
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  # ⚠️ #692 had just fixed this helper the other way, by finding "the" declaring
  # control through data-filter-control: the ticket select declared a rule of its
  # own and rendered first, so reading the query-toggle attributes walked the
  # wrong control. S7 removes both selects, so there is no first and second
  # control left to confuse -- the option link IS the declaration.
  # The declaration ONE billing option carries, as [key, value] pairs.
  #
  # ⚠️ Read off a link since S7. The billing used to be a select, so the
  # widening was declared once on the control and the chosen id had to be
  # appended from the control's NAME (lib/query_toggle.js #choiceQuery, and the
  # "read the hidden input, never write the name out" dance this helper did).
  # It is a menu of links now: every option owns the widening AND its own id, so
  # there is one declaration to read and no second half that can go missing.
  def billing_option(group, scope = doc)
    scope.at_css(%([data-filter-pill="billing"] a[data-filter-pill-option="#{group.id}"]))
  end

  def choice_owns(group, scope = doc)
    element = billing_option(group, scope)
    element && JSON.parse(element['data-query-toggle-owns'])
  end

  # Whether the billing can be picked at all. The control used to be dropped
  # from the markup entirely; since S7 it stays as a dampened pill that gives
  # the reason (E2), so "not offered" is a STATE now, not an absence, and an
  # example that only asked "is it gone" would go green on a pill nobody can
  # read the reason of.
  def billing_pill_state(scope = doc)
    scope.at_css('[data-filter-pill="billing"]')&.[]('data-filter-pill-state')
  end

  # What lib/query_toggle.js #choiceQuery builds: the owned keys leave the live
  # query in BOTH spellings, then the pairs and the chosen value are appended,
  # and page goes. Written out rather than hand-assembled per example, so an
  # example cannot quietly assert a different rule than the browser follows.
  # The lib points back here; a change on one side is a change on the other.
  def address_for_choosing(group, from: {})
    params = from.each_with_object([]) { |(key, value), acc| Array(value).each { |v| acc << [key.to_s, v.to_s] } }
    owned = choice_owns(group)
    # Delete every owned key FIRST, in both spellings, and only then append.
    # Not one loop: appending "status_filters[]=billed" and then deleting for
    # the next pair would take the one just written with it.
    owned.map(&:first).each do |key|
      bare = key.delete_suffix('[]')
      params.reject! { |name, _| [bare, "#{bare}[]"].include?(name) }
    end
    # A changed filter starts again at the first page, in the lib and here.
    params.reject! { |name, _| name == 'page' }
    owned.each { |key, value| params << [key, value] if value.present? }
    # Built by hand, NOT through to_query on a Hash: status_filters[] appears
    # three times and a Hash keeps only the last of them, which silently turns
    # "all three states" into "billed" and makes this helper assert a rule the
    # browser does not follow.
    query = params.map { |key, value| "#{CGI.escape(key)}=#{CGI.escape(value)}" }.join('&')
    "#{organisation_time_sessions_path(organisation)}?#{query}"
  end

  def rows_in_body
    doc.css('#time_sessions_body [data-ticket-group-key-value]').size
  end

  # The sum at the FOOT of the list, added up over every month on screen. The
  # right oracle for "all of the billing's hours are here": a row is one subject
  # in one MONTH, so two bookings two months apart are two rows of 01:00 and
  # never one of 02:00. Reading the row durations would pass on half the hours.
  def visible_sum
    label = I18n.t('views.time_sessions.billing_status.visible_sum')
    foot = doc.css('#time_sessions_table > div').find { |node| node.text.include?(label) }
    foot&.css('.font-mono')&.first&.text.to_s.strip
  end

  describe 'what the choice declares' do
    it 'opens the period, switches all three states on and drops the old bounds' do
      group = with_tenant { create(:time_session_group, organisation: organisation, name: 'Juli 2026') }
      book(group: group)

      get_list

      owns = choice_owns(group)
      expect(owns).to include(%w[date_range all], ['start_date', ''], ['end_date', ''])
      # The legacy single-value param is a status filter too. Left standing it
      # would go on narrowing under three open pills.
      expect(owns).to include(['billing_status', ''])
      TimeSession::BILLING_STATUS_FILTERS.each do |state|
        expect(owns).to include(['status_filters[]', state])
      end

      # The id travels under the key the controller filters on, or the address
      # would carry it under a name nobody reads. It is part of the option's own
      # declaration now rather than something read off a control's name.
      expect(owns).to include(['time_session_group_id', group.id])
      # And the option has to sit inside the controller that rewrites it, or the
      # action is dead markup and the request spec never knows.
      expect(billing_option(group).ancestors('[data-controller~="query-toggle"]')).not_to be_empty
    end

    it 'is offered again as soon as a second state stands beside "ohne Abrechnung"' do
      # One step past the boundary: the rule is "exactly that one state", not
      # "that state among others". Loosened to include?, the example below
      # would stay green and the picker would vanish here.
      group = with_tenant { create(:time_session_group, organisation: organisation) }
      book(group: group)

      get_list(status_filters: %w[without_billing in_billing])

      expect(billing_pill_state).to eq('open')
      expect(choice_owns(group)).to be_present
    end

    it 'is not offered at all while the status filter is exactly "ohne Abrechnung"' do
      # The other half of the same rule: a session in a billing is by definition
      # not without one, so there is nothing to pick.
      group = with_tenant { create(:time_session_group, organisation: organisation) }
      book(group: group)

      get_list(status_filters: ['without_billing'])

      # ⚠️ It is not GONE any more, it is locked (E2). Dropping the control made
      # the row jump and explained nothing; the pill now stays in place and
      # carries the reason. An example that only asked "did it disappear" would
      # pass just as well on a pill with no reason on it at all.
      expect(billing_pill_state).to eq('locked')
      expect(choice_owns(group)).to be_nil
      pill = doc.at_css('[data-filter-pill="billing"]')
      expect(pill.text).to include(I18n.t('views.organisations.time_sessions.index.filter_group_locked'))
    end
  end

  describe 'what the list then shows' do
    let(:group) { with_tenant { create(:time_session_group, organisation: organisation, name: 'Juli 2026') } }

    before do
      book(group: group, on: 2.months.ago) # outside the default period
      book(group: group, on: Date.current, billed: true) # outside the default status
    end

    it 'shows every hour of the billing, whenever it was booked and whatever its state' do
      get_list

      get address_for_choosing(group)
      expect(response).to have_http_status(:ok)

      # Two rows, because a row is a subject in a MONTH, and 02:00 together.
      expect(rows_in_body).to eq(2)
      expect(visible_sum).to eq('02:00')
    end

    it 'clears a custom period, not just the named one' do
      # date_range=all alone does not undo a hand-set window: the controller
      # reads start_date/end_date FIRST and calls the range 'custom' when either
      # is there. Both bounds have to leave with it.
      get_list(start_date: 1.week.ago.to_date.to_s, end_date: Date.current.to_s)

      address = address_for_choosing(group, from: { start_date: 1.week.ago.to_date.to_s,
                                                    end_date: Date.current.to_s })
      expect(address).not_to include('start_date')
      expect(address).not_to include('end_date')

      get address
      expect(visible_sum).to eq('02:00')
    end

    it 'takes the legacy single-value status with it, or three open pills would still narrow' do
      # An old address may still carry the legacy billing_status. The service
      # ignores it under three open states since the S4 review; the choice drops
      # it from the address as well, because a filter nobody can see does not
      # belong there. Followed, not just declared.
      #
      # ⚠️ status_filters travels WITH the legacy param on purpose. billing_status
      # alone empties @effective_status_filters, and the picker is then tailored
      # to nothing: no billing is offered at all. The old version of this example
      # asked the SELECT for its declaration, and a select exists whether or not
      # it has options -- so it followed an address no reader on that page could
      # have reached. Reading one OPTION says it plainly.
      get_list(status_filters: %w[in_billing billed], billing_status: 'unbilled')

      address = address_for_choosing(group, from: { status_filters: %w[in_billing billed],
                                                    billing_status: 'unbilled' })
      expect(address).not_to include('billing_status')

      get address
      expect(visible_sum).to eq('02:00')
    end

    it 'starts again at the first page' do
      # A page of the narrow result means nothing in the wide one. The lib
      # drops it; this mirror has to, or the example would follow an address
      # the browser never visits.
      get_list

      address = address_for_choosing(group, from: { page: 2 })
      expect(address).not_to include('page=')

      get address
      expect(rows_in_body).to eq(2)
    end

    # The before/after in one example: the same billing, chosen WITHOUT the
    # widening, is the empty list this slice exists to prevent.
    it 'would show nothing if the choice carried only the billing' do
      get_list(time_session_group_id: group.id)

      expect(rows_in_body).to be_zero
    end

    it 'keeps a filter the choice knows nothing about' do
      other_project = with_tenant { create(:project, organisation: organisation, name: 'Nebenprojekt') }
      with_tenant do
        create(:time_session, organisation: organisation, project: other_project, creator: admin,
                              duration: 60, occurred_on: 2.months.ago, time_session_group: group)
      end

      get_list(project_id_filter: project.id)

      address = address_for_choosing(group, from: { project_id_filter: project.id })
      expect(address).to include("project_id_filter=#{project.id}")

      get address
      # The billing holds 03:00 in all, one of them in the other project. The
      # sum is the oracle: a project NAME is in every response, the select
      # lists them all, and would prove nothing.
      expect(visible_sum).to eq('02:00')
    end
  end

  describe 'and the pills say so' do
    # D2: the widening happens in the ADDRESS and not behind the reader's back,
    # so every filter it moved can be seen and put back.
    let(:group) { with_tenant { create(:time_session_group, organisation: organisation) } }

    before { book(group: group, on: 2.months.ago) }

    # Every period label, the custom pill's included: an aria-current that a
    # segment ALWAYS claimed would survive any include-assertion, so the two
    # examples below intersect against the full list and expect exactly one.
    let(:range_labels) do
      TimeSessions::ListPeriod::LIST_KEYS.map { |key| TimeSessions::ListPeriod.label(key) }
    end

    def current_labels
      # The first non-empty line: a status pill carries its hours on the line
      # after its word. The chosen menu option's check mark is NOT in here --
      # it is drawn by CSS precisely so it stays out of the label (and out of a
      # screen reader's mouth), after a text node cost three specs their oracle.
      doc.css('[aria-current="true"]').map do |node|
        node.text.split("\n").map(&:strip).reject(&:empty?).first
      end
    end

    it 'marks all three status pills and the "alles" period as current' do
      get_list

      get address_for_choosing(group)

      current = current_labels
      TimeSession::BILLING_STATUS_FILTERS.each do |state|
        expect(current).to include(I18n.t("views.time_sessions.billing_status.#{state}"))
      end
      # Exactly ONE period segment is current, and it is "alles".
      expect(current & range_labels).to eq([I18n.t('views.organisations.time_sessions.index.filter_range_all')])
    end

    # The custom pill's other direction (S4 review: it was styled active
    # without saying so): hand-set bounds make it the one current segment.
    it 'marks only the custom pill current while hand-set bounds stand' do
      get_list(start_date: 3.months.ago.to_date.to_s, end_date: Date.current.to_s)

      expect(current_labels & range_labels)
        .to eq([I18n.t('views.organisations.time_sessions.index.filter_range_custom')])
    end
  end
end
