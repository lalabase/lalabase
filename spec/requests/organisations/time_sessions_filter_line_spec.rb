# frozen_string_literal: true

require 'rails_helper'

# What: The filter LINE of the time list. S7 of
#       doc/zeiten_filterzeile_und_stand_plan.md (finding F7, decisions E1-E5).
# Type: Request spec. Everything asserted here is decided in Ruby; the browser
#       half is a <details> (which needs no JavaScript at all) plus
#       details-autoclose, whose own behaviour is not this file's business.
# Why:  The filter was a box of three rows sorted by TOPIC, with fourteen
#       always-visible targets, nine of them for the single question "which
#       period". It is two rows sorted by INTERACTION now: what you pick above,
#       what you switch below.
#
#       The oracle is the STATE a pill declares (data-filter-pill-state) and the
#       ADDRESS its options lead to, not the pill's text. A label can read right
#       while the link underneath it clears the wrong filter, and that is the
#       failure this surface has had twice (S2's pills pointing at the address
#       the page was opened with, S4's owns pairs written out a second time).
RSpec.describe 'Time list: the filter line', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:project)      { with_tenant { create(:project, organisation: organisation, name: 'Shop Relaunch') } }
  let(:other_project) { with_tenant { create(:project, organisation: organisation, name: 'Wartung') } }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant { create(:membership, user: admin, organisation: organisation, role: admin_role, active: true) }
    sign_in admin
  end

  after { ActsAsTenant.current_tenant = nil }

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def book(on: Date.current, minutes: 60, **attrs)
    with_tenant do
      create(:time_session, organisation: organisation, project: project, creator: admin,
                            duration: minutes, occurred_on: on, **attrs)
    end
  end

  def get_list(**params)
    get organisation_time_sessions_path(organisation, **params)
    expect(response).to have_http_status(:ok)
  end

  def doc = Nokogiri::HTML(response.body)

  def pill(key, scope = doc) = scope.at_css(%([data-filter-pill="#{key}"]))
  def pill_state(key, scope = doc) = pill(key, scope)&.[]('data-filter-pill-state')

  # The ✕, which is a LINK and not a glyph: what it removes is the thing under
  # test, not that something is drawn.
  def clear_link(key, scope = doc)
    pill(key, scope)&.at_css('summary a[data-query-toggle-owns]')
  end

  def options(key, scope = doc)
    pill(key, scope)&.css('a[data-filter-pill-option]') || []
  end

  def reset_link(scope = doc) = scope.at_css('#time_filter_reset a[data-filter-reset]')

  # One booking, so the list is not in first-use state (which hides the filters
  # entirely, and would make every example below vacuum-green).
  before { book }

  describe 'the four choices' do
    it 'offers period, project, subject and billing, in that reading order' do
      get_list

      # No scoping needed: the display chooser is drawn by the same partial but
      # wears its own handle, so "every filter pill on the page" is exactly the
      # four. This used to be scoped to the panel to work around the chooser
      # answering to data-filter-pill as well.
      keys = doc.css('[data-filter-pill]').map { |node| node['data-filter-pill'] }
      expect(keys).to eq(%w[period project subject billing])
    end

    it 'gives an unchosen filter the open state and its bare name' do
      get_list

      expect(pill_state(:project)).to eq('open')
      # The SUMMARY, not the whole <details>: the menu below it lists every
      # project by name, so asking the pill as a whole what it says would find
      # the value in the options and pass on a pill that names nothing.
      summary = pill(:project).at_css('summary').text
      expect(summary).to include(I18n.t('views.organisations.time_sessions.empty_reason.names.project'))
      expect(summary).not_to include('Shop Relaunch')
      expect(clear_link(:project)).to be_nil
    end

    it 'gives a chosen filter the set state, its value and a ✕ that removes exactly it' do
      get_list(project_id_filter: project.id)

      expect(pill_state(:project)).to eq('set')
      expect(pill(:project).at_css('summary').text).to include('Shop Relaunch')

      cleared = Rack::Utils.parse_nested_query(URI.parse(clear_link(:project)['href']).query)
      expect(cleared.keys).not_to include('project_id_filter')
    end

    # ⚠️ There is no list without a period, only a different one. A ✕ on it would
    # promise a state that does not exist, and following it would land on the
    # default -- which is not "no period" but a filter of its own.
    it 'never offers to clear the period, which is always set' do
      get_list(date_range: 'all')

      expect(pill_state(:period)).to eq('set')
      expect(clear_link(:period)).to be_nil
    end

    it 'names the period by its preset, not by its dates' do
      get_list(date_range: 'this_week')

      expect(pill(:period).at_css('summary').text).to include(TimeSessions::ListPeriod.label('this_week'))
    end
  end

  # A preset speaks its name; two hand-typed days speak for themselves.
  describe 'the custom period' do
    def custom(**params) = get_list(date_range: 'custom', **params)

    it 'wears its two dates, with the year only once' do
      custom(start_date: '2026-06-01', end_date: '2026-08-31')

      summary = pill(:period).at_css('summary').text.squish
      # ⚠️ The whole string, dash included. Asserting only the two dates left the
      # separator unpinned, and the constant spent a while printing the six
      # characters "\u2013" between them: Ruby does not read that escape inside
      # single quotes, and both dates were still exactly where they belonged.
      expect(summary).to eq("01.06. \u2013 31.08.2026")
      # Not the preset's name, which says nothing about WHICH period this is,
      # and not the filter's name either: two dates joined by a dash are not
      # mistakable for anything else, and the prefix is the widest thing in the
      # row.
      expect(summary).not_to include(TimeSessions::ListPeriod.label('custom'))
      expect(summary).not_to include(I18n.t('views.organisations.time_sessions.empty_reason.names.period'))
    end

    it 'keeps the year on both bounds when they differ' do
      custom(start_date: '2025-11-01', end_date: '2026-02-28')

      expect(pill(:period).at_css('summary').text.squish).to include('01.11.2025', '28.02.2026')
    end

    # ⚠️ Choosing "eigener Zeitraum" is a page visit, and the two date fields
    # live in that pill's menu. Rendered closed, the reader lands on an answer
    # with no way to type the dates they just asked for -- the whole point of
    # the choice, unreachable.
    it 'opens its menu, because that is where the fields are' do
      custom

      expect(pill(:period)['open']).not_to be_nil
      expect(pill(:period).at_css('input[name$="start_date"]')).to be_present
      expect(pill(:period).at_css('input[name$="end_date"]')).to be_present
    end

    it 'leaves the other pills closed' do
      custom

      expect(pill(:project)['open']).to be_nil
    end

    # The other half of "the button closes the panel". The button does it in the
    # browser (the form aims at the list frame, so nothing reloads); the server
    # has to agree, or the next full load would prise the panel back open over
    # an answer the reader already has.
    it 'closes again once the span is settled' do
      custom(start_date: '2026-06-01', end_date: '2026-08-31')

      expect(pill(:period)['open']).to be_nil
    end

    it 'says which mode it is in before anything is typed' do
      custom

      expect(pill(:period).at_css('summary').text.squish)
        .to include(TimeSessions::ListPeriod.label('custom'))
    end

    it 'stays open while only one bound is typed' do
      custom(start_date: '2026-06-01')

      expect(pill(:period)['open']).not_to be_nil
    end

    # ⚠️ The button changes the PERIOD, and the period pill sits outside the list
    # frame. A frame answer updated the list and left the pill reading "Eigener
    # Zeitraum" over a list of June to August -- the S4 trap, one control later.
    it 'applies as a whole-page visit, not into the list frame' do
      custom(start_date: '2026-06-01', end_date: '2026-08-31')

      expect(pill(:period).at_css('input[type=submit]')['data-turbo-frame']).to eq('_top')
    end

    it 'shows the applied dates on the pill afterwards' do
      custom(start_date: '2026-06-01', end_date: '2026-08-31')

      expect(pill(:period).at_css('summary').text.squish).to include('01.06.', '31.08.2026')
    end

    it 'hands the apply button the action that closes the panel' do
      custom(start_date: '2026-06-01', end_date: '2026-08-31')

      apply = pill(:period).at_css('input[type=submit]')
      # ⚠️ details-autoclose#close, not a close of its own. That controller is
      # already mounted on this <details> and already owns closing it; the button
      # walking the DOM for the element was a third way to do one thing.
      expect(apply['data-action']).to include('details-autoclose#close')
    end

    # ⚠️ A range is ONE decision out of TWO controls. Submitting when the first
    # changes applies a span half of which the reader has not chosen, so the
    # fields opt out of the auto-submit and the button does the applying.
    it 'gives the fields an apply button and keeps them out of the auto-submit' do
      custom(start_date: '2026-06-01', end_date: '2026-08-31')

      %w[start_date end_date].each do |field|
        input = pill(:period).at_css(%(input[name$="#{field}"]))
        expect(input['data-auto-submit-skip']).not_to be_nil, "#{field} would submit on its own"
      end
      expect(pill(:period).at_css('input[type=submit]')).to be_present
    end

    it 'counts both bounds, inclusively, beside the button' do
      custom(start_date: '2026-06-01', end_date: '2026-08-31')

      # 92, not 91: a period includes both its days, the way the filter service
      # reads them. Rendered by the server, so the panel is complete with no
      # JavaScript at all.
      expect(pill(:period).text).to include(
        I18n.t('views.organisations.time_sessions.index.filter_range_days', count: 92)
      )
    end

    it 'applies the typed range to the list' do
      inside = book(on: Date.new(2026, 7, 15))
      outside = book(on: Date.new(2026, 10, 15))

      custom(start_date: '2026-06-01', end_date: '2026-08-31')

      expect(response.body).to include(inside.id)
      expect(response.body).not_to include(outside.id)
    end
  end

  describe 'the subject, across projects (D4)' do
    let!(:here)  { with_tenant { create(:meeting, project: project, organisation: organisation, creator: admin, title: 'Jour fixe') } }
    let!(:there) { with_tenant { create(:meeting, project: other_project, organisation: organisation, creator: admin, title: 'Jour fixe') } }

    before do
      book(meeting: here)
      with_tenant do
        create(:time_session, organisation: organisation, project: other_project, creator: admin,
                              duration: 60, occurred_on: Date.current, meeting: there)
      end
    end

    # Until S6 the subject could only be filtered inside a project, so the
    # control was rendered only once a project had been picked and the row
    # jumped when it appeared. The pill keeps its place now.
    it 'is selectable with no project chosen' do
      get_list

      expect(pill_state(:subject)).to eq('open')
      expect(options(:subject).size).to be > 1
    end

    # ⚠️ The case S6 exists for: two meetings of the same title. Without the
    # project beside them the menu offers the same word twice and a reader
    # cannot tell which one they are picking.
    it 'tells two namesakes apart by their project' do
      get_list

      labelled = options(:subject).map { |node| node.text.squish }
      expect(labelled.count { |text| text.include?('Jour fixe') }).to eq(2)
      expect(labelled.any? { |text| text.include?('Shop Relaunch') }).to be(true)
      expect(labelled.any? { |text| text.include?('Wartung') }).to be(true)
    end

    it 'sets one subject id and clears the other, because a booking has one subject' do
      get_list

      option = options(:subject).find { |node| node['data-filter-pill-option'] == there.id }
      owns = JSON.parse(option['data-query-toggle-owns'])
      expect(owns).to include(['meeting_id', there.id], ['ticket_id', ''])
    end

    # ⚠️ Deleting `filterable: true` from the two long menus broke no example, so
    # the field could have vanished without a sound. The subject menu reaches
    # across every project since S6 and the billing menu grows over a year;
    # neither is scrollable-by-eye for long.
    it 'gives the long menus a field to narrow them by' do
      get_list

      %w[subject billing].each do |key|
        expect(pill(key).at_css('[data-filter-menu-search-target="query"]'))
          .to be_present, "the #{key} menu has no way to be narrowed"
      end
      # And the short ones do not, or every menu would open with a field in it.
      expect(pill(:period).at_css('[data-filter-menu-search-target="query"]')).to be_nil
    end

    # ⚠️ The N+1 the menu had. The label of every option goes through
    # time_session_subject_presentation, which reads project.organisation to
    # build a route -- so the menu asked for one organisation per project per
    # subject type unless the preload reached that far.
    #
    # The oracle is the SHAPE of the query, not a total: a per-row belongs_to
    # reads organisations with an equality on the id, a preload uses IN(...).
    # A total would drift with every unrelated query the page grows, and this
    # has to still fail in a year. Prosopite does not answer here -- the
    # repetition is inside one render and it stays under its threshold -- which
    # is exactly why the suite could not see this (review of #693).
    def organisation_by_id_queries(&)
      statements = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        next if %w[SCHEMA TRANSACTION CACHE].include?(payload[:name])

        statements << payload[:sql]
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
      statements.count { |sql| sql.match?(/FROM "organisations".*"organisations"\."id" = /m) }
    end

    def add_subject_project(name)
      extra = with_tenant { create(:project, organisation: organisation, name: name) }
      m = with_tenant { create(:meeting, project: extra, organisation: organisation, creator: admin, title: "Runde #{name}") }
      with_tenant do
        create(:time_session, organisation: organisation, project: extra, creator: admin,
                              duration: 30, occurred_on: Date.current, meeting: m)
      end
    end

    it 'does not read one more organisation for every project in the menu' do
      add_subject_project('Zweites')
      narrow = organisation_by_id_queries { get_list }
      narrow_options = options(:subject).size

      %w[Drittes Viertes Fuenftes].each { |name| add_subject_project(name) }
      wide = organisation_by_id_queries { get_list }

      # The menu really did grow, or the comparison below proves nothing.
      expect(options(:subject).size).to be > narrow_options
      # ⚠️ The DELTA, not the total: this page reads organisations for plenty of
      # reasons that have nothing to do with the menu, and a fixed total would
      # drift with every one of them. What must not happen is the count rising
      # WITH the number of projects the menu names.
      expect(wide).to eq(narrow),
                      "three more projects in the menu cost #{wide - narrow} more organisation reads"
    end

    it 'offers only subjects that actually have booked time' do
      unbooked = with_tenant { create(:meeting, project: project, organisation: organisation, creator: admin, title: 'Nie gebucht') }
      get_list

      expect(options(:subject).map { |node| node['data-filter-pill-option'] }).not_to include(unbooked.id)
    end
  end

  # ⚠️ Every option is a server-rendered link, and the whole line is re-rendered
  # on the frame answer of a search and then thrown away. Measured before the
  # cap, on ten projects with a hundred tickets each: 1001 links and 634 KB for
  # this one menu. The budget is a display decision, so it is stubbed small here
  # rather than fed 51 records.
  describe 'how many subjects the menu offers (review of #693)' do
    def ticket_with_time(title, on:, in_project: project)
      with_tenant do
        ticket = create(:ticket, project: in_project, organisation: organisation, title: title)
        create(:time_session, organisation: organisation, project: in_project, creator: admin,
                              duration: 60, occurred_on: on, ticket: ticket)
        ticket
      end
    end

    def subject_ids = options(:subject).map { |node| node['data-filter-pill-option'] }
    def capped_notice = pill(:subject).text.include?(I18n.t('views.organisations.time_sessions.index.filter_subject_capped', count: 2))

    before { stub_const('Organisations::TimeSessionsController::MAX_FILTER_SUBJECTS', 2) }

    # The cut is by RECENCY, not by title. An alphabetical cut would drop a
    # subject for the accident of its name, and "what did I work on lately" is
    # the question this menu answers.
    it 'keeps the most recently booked and drops the oldest' do
      old    = ticket_with_time('Aaa uralt', on: 90.days.ago)
      recent = ticket_with_time('Zzz gestern', on: 1.day.ago)
      middle = ticket_with_time('Mmm letzte Woche', on: 7.days.ago)

      get_list

      expect(subject_ids).to include(recent.id, middle.id)
      expect(subject_ids).not_to include(old.id)
    end

    it 'says that it is showing a window' do
      3.times { |i| ticket_with_time("Ticket #{i}", on: i.days.ago) }

      get_list

      expect(subject_ids.compact_blank.size).to eq(2)
      expect(capped_notice).to be(true)
    end

    # n-1: exactly the budget is not a cut, and a menu that cried "window" at its
    # own complete contents would be lying in the commoner direction.
    it 'stays silent at exactly the budget' do
      2.times { |i| ticket_with_time("Ticket #{i}", on: i.days.ago) }

      get_list

      expect(subject_ids.compact_blank.size).to eq(2)
      expect(capped_notice).to be(false)
    end

    # The one option a menu must always contain is the one it is showing. The
    # cap is by recency and the choice is the reader's, so an old subject would
    # otherwise vanish out of its own pill.
    it 'pins the chosen subject even when the cap would have dropped it' do
      old = ticket_with_time('Im letzten Quartal', on: 120.days.ago)
      2.times { |i| ticket_with_time("Frisch #{i}", on: i.days.ago) }

      get_list(ticket_id: old.id, date_range: 'all')

      expect(subject_ids).to include(old.id)
      expect(pill_state(:subject)).to eq('set')
    end

    # The billing pill has narrowed to the chosen project since long before S7
    # ("Additionally filter by project" in #index). The subject pill sat right
    # beside it and answered to a different rule, and the one that ignored the
    # project was also the one without a bound.
    it 'narrows to the chosen project, the way the billing beside it does' do
      stub_const('Organisations::TimeSessionsController::MAX_FILTER_SUBJECTS', 50)
      mine = ticket_with_time('Im Shop Relaunch', on: 1.day.ago)
      elsewhere = ticket_with_time('In der Wartung', on: 1.day.ago, in_project: other_project)

      get_list
      expect(subject_ids).to include(mine.id, elsewhere.id)

      get_list(project_id_filter: project.id)
      expect(subject_ids).to include(mine.id)
      expect(subject_ids).not_to include(elsewhere.id)
    end

    # D4 is what the cap must not cost: with no project chosen the menu still
    # reaches across all of them.
    it 'still reaches across projects when none is chosen' do
      stub_const('Organisations::TimeSessionsController::MAX_FILTER_SUBJECTS', 50)
      ticket_with_time('Hier', on: 1.day.ago)
      ticket_with_time('Dort', on: 1.day.ago, in_project: other_project)

      get_list

      projects_named = options(:subject).map { |node| node.text.squish }
      expect(projects_named.any? { |text| text.include?('Shop Relaunch') }).to be(true)
      expect(projects_named.any? { |text| text.include?('Wartung') }).to be(true)
    end
  end

  # E2: the rule is unchanged, its answer moved from "gone" to "not now, and
  # here is why".
  describe 'the billing while only unbilled time is shown (E2)' do
    it 'stays in place, dampened, and gives the reason' do
      get_list(status_filters: ['without_billing'])

      expect(pill_state(:billing)).to eq('locked')
      expect(pill(:billing).text).to include(
        I18n.t('views.organisations.time_sessions.index.filter_group_locked')
      )
      expect(options(:billing)).to be_empty
    end

    # One step past the boundary: the rule is "exactly that one state", not
    # "that state among others".
    it 'is selectable again as soon as a second state stands beside it' do
      get_list(status_filters: %w[without_billing in_billing])

      expect(pill_state(:billing)).to eq('open')
    end
  end

  # E5: the reset exists only while something narrows the list, and "something"
  # includes the search and "Nur meine Zeiten".
  describe 'the reset (E5)' do
    it 'is absent on the default address, where nothing narrows' do
      get_list

      expect(reset_link).to be_nil
    end

    # ⚠️ WHERE it stands, not just that it stands. It has now sat in three places
    # -- the choice row, the status row, and since 02.09.2026 the bottom right of
    # the panel -- and not one example noticed a move, because they all only
    # asked whether the link existed. It governs the whole box, so it belongs at
    # the box's end; on the status row it read as a reset of the three states.
    it 'stands in the last row of the panel, not beside the status boxes' do
      get_list(date_range: 'all')

      reset = reset_link
      expect(reset).to be_present
      expect(reset.ancestors('#time_status_pills')).to be_empty,
                                                       'the reset sits inside the status row'
      # In the same row as the search, which is the panel's last one.
      row = doc.at_css('#time_filter_reset').parent
      expect(row.at_css('#searchInput')).to be_present,
                                            'the reset is not in the panel\'s last row'
    end

    it 'appears once the period deviates from the default' do
      get_list(date_range: 'all')

      expect(reset_link).to be_present
    end

    # ⚠️ The search is the reason this link has to travel with the frame answer
    # at all (E1): it narrows the list from a form that targets the list frame,
    # so on a frame request the reset has to arrive with it or a search would
    # empty the list and leave no way back.
    it 'appears for a search alone' do
      get_list(search: 'nichts das passt')

      expect(reset_link).to be_present
    end

    # ⚠️ A smart folder narrows the list and has NO control of its own, so the
    # reset is the only way out of it. It was unconditional before E5 tied it to
    # a count -- and that count did not know about folders, so the list came back
    # narrowed with a badge reading zero and nothing offering a way back.
    # EmptyReason leaves the folder out deliberately, reasoning that "the view
    # answers that with the reset link, which drops the folder too": true while
    # the link was unconditional, false the moment it depended on this.
    it 'appears for a smart folder, which has no control of its own' do
      folder = with_tenant do
        create(:smart_folder, organisation: organisation, user: admin,
                              target_object_type: 'TimeSession', name: 'Meine')
      end

      get_list(smart_folder_id: folder.id)

      expect(reset_link).to be_present, 'a smart folder narrows the list with no way back out'
      expect(doc.at_css('[data-filter-count]')['data-filter-count']).to eq('1')
    end

    it 'appears for "Nur meine Zeiten" alone' do
      get_list(creator_id: admin.id)

      expect(reset_link).to be_present
    end

    # Not the bare address: that re-applies the two defaults (this month, billed
    # hidden) and, in the case a reader needs this link for, leads to the same
    # empty page again.
    it 'leads to the neutral list and is FOLLOWED to a wider one' do
      old_billed = book(on: 8.months.ago, billed: true)
      get_list(date_range: 'this_week')

      get reset_link['href']
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(old_billed.id)
    end

    # ⚠️ The example above follows the link and never looks back at it, and that
    # is how the link survived its own click for a while: the neutral list is
    # all time and all three states, which DEVIATES from the default by two, so
    # the reset re-rendered on the widest possible list and pointed at the page
    # already on screen. The badge read "2" there for the same reason.
    # Found in review of #693; the rule is time_filter_reset_offered?.
    it 'is gone once it has been followed' do
      book(on: 8.months.ago, billed: true)
      get_list(date_range: 'this_week')

      get reset_link['href']

      expect(reset_link).to be_nil, 'the reset points at the page it is standing on'
    end

    # ⚠️ The mobile badge still reads 2 here, and deliberately so for now: it
    # counts DEVIATION FROM THE DEFAULT, which #692 settled one commit before
    # this one, and "all time, all three states" deviates by two. The reset asks
    # a different question -- would following me change anything -- so the two
    # part ways exactly on the neutral list. Pinned rather than fixed, because
    # changing what the badge counts is #692's decision to revisit, not S7's to
    # override in passing.
    it 'parts ways with the badge on the neutral list, on purpose' do
      get_list(date_range: 'all', status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(reset_link).to be_nil
      expect(doc.at_css('[data-filter-count]')['data-filter-count']).to eq('2')
    end

    # The other side of the same rule: reaching the neutral state BY HAND, not
    # through the link, has to answer the same way. Otherwise the predicate is
    # about the link's history rather than about the list.
    it 'is gone on a hand-typed neutral address too' do
      get_list(date_range: 'all', status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(reset_link).to be_nil
    end

    # n-1: one step off the neutral state and it is back, or the check above
    # would pass on a reset that never renders at all.
    it 'is back as soon as one state is switched off again' do
      get_list(date_range: 'all', status_filters: %w[without_billing in_billing])

      expect(reset_link).to be_present
    end

    # ⚠️ EVERY out-of-frame region, not just the reset. Each of these is a
    # reading of the query the frame answers, and Turbo swaps the frame and
    # leaves the rest of the page alone -- so one that does not travel keeps the
    # figure the page was opened with.
    #
    # This example exists because two of them did not travel and nothing noticed:
    # the result row and the hits figure were added outside the frame, and every
    # assertion about them was a full page load, which can never see the
    # difference. Asked of the LIST now, so a fifth region joins it by being in
    # FRAME_DEPENDENT_REGIONS rather than by someone remembering to add a case.
    it 'brings every out-of-frame region back with a frame answer' do
      get organisation_time_sessions_path(organisation, search: 'nichts das passt'),
          headers: { 'Turbo-Frame' => 'time_sessions_list_frame' }

      frame = Nokogiri::HTML(response.body).at_css('turbo-frame#time_sessions_list_frame')
      expect(frame).to be_present

      TimeSessionsHelper::FRAME_DEPENDENT_REGIONS.each do |region|
        expect(frame.at_css(%(turbo-stream[target="time_#{region}"])))
          .to be_present, "#{region} does not travel with the frame answer"
      end
    end

    # The other half: a region that travels is no use if it arrives with the old
    # number in it. The search narrows to nothing, so the count has to say so.
    it 'brings the NEW figures, not a copy of the old ones' do
      book(on: Date.current)
      get organisation_time_sessions_path(organisation, search: 'zzz-nichts-das-passt'),
          headers: { 'Turbo-Frame' => 'time_sessions_list_frame' }

      frame = Nokogiri::HTML(response.body).at_css('turbo-frame#time_sessions_list_frame')
      summary = frame.at_css('turbo-stream[target="time_result_summary"] template').inner_html
      expect(Nokogiri::HTML(summary).text.squish).to start_with('0 Zeiten')
    end

    # ⚠️ Position, not presence. A <turbo-stream> placed after </turbo-frame> is
    # in the body, renders in a request spec and is thrown away by the browser
    # (reference: a turbo-stream after the frame is discarded). The element has
    # to travel INSIDE the frame to travel at all.
    it 'arrives inside the frame on a frame request, not after it' do
      get organisation_time_sessions_path(organisation, search: 'nichts das passt'),
          headers: { 'Turbo-Frame' => 'time_sessions_list_frame' }

      frame = Nokogiri::HTML(response.body).at_css('turbo-frame#time_sessions_list_frame')
      expect(frame).to be_present
      expect(frame.at_css('turbo-stream[target="time_filter_reset"]')).to be_present
    end
  end

  # The search answers "which words", the panel answers "which bookings". It sits
  # with the display toggles, which change the VIEW, not the set.
  describe 'where the search sits' do
    # ⚠️ It has now moved TWICE: it started above the panel, went to the display
    # row, and the handout of 02.09.2026 put it INSIDE the panel as its third
    # row. Each move was a decision about what it IS -- and the last one settles
    # it: everything in the panel decides WHAT is in the list, and a search does
    # exactly that. The row below reports the answer instead.
    it 'sits inside the filter panel, not on the result row' do
      get_list

      field = doc.at_css('#searchInput')
      expect(field).to be_present

      panel = doc.css('[data-controller~="query-toggle"]').find { |n| n.at_css('#searchInput') }
      expect(panel).to be_present, 'the search is not inside the filter panel'

      result_row = doc.at_css('[data-result-summary]')&.parent
      expect(result_row).to be_present
      expect(result_row.css('#searchInput')).to be_empty
    end

    # ⚠️ ONE form on this panel, and that is the whole point of the move.
    #
    # The search used to be a form of ITS OWN, re-emitting every query parameter
    # as a hidden field under the same name to the same address. That is why the
    # subject ids need data-filter-state at all: a selector on the name found
    # whichever copy came first. Putting the search INSIDE the panel as a nested
    # form would have been strictly worse -- a form inside a form does not
    # survive the parser -- so it became a FIELD, and the duplication went away
    # with the second form.
    #
    # This example is what keeps it away: a second form here, or a hidden search
    # field beside the real one, and a parameter is sent twice again.
    it 'carries each filter parameter exactly once, because the panel has one form' do
      meeting = with_tenant { create(:meeting, project: project, organisation: organisation, creator: admin, title: 'Jour fixe') }
      book(meeting: meeting)

      get_list(meeting_id: meeting.id, search: 'kickoff')

      panel = doc.css('[data-controller~="query-toggle"]').find { |n| n.at_css('#searchInput') }
      expect(panel.css('form').size).to eq(1), 'the panel grew a second form'

      %w[meeting_id search].each do |name|
        fields = panel.css(%(form [name="#{name}"]))
        expect(fields.size).to eq(1), "#{name} is sent #{fields.size} times"
      end

      # The handle still points at the real field, which is set by a LINK and so
      # still has to travel hidden.
      handled = doc.at_css('input[data-filter-state="meeting_id"]')
      expect(handled).to be_present
    end

    it 'reports the same number the result row does' do
      get_list(search: 'zzz-nichts-das-passt')

      hits = doc.at_css('[data-search-hits]')
      expect(hits).to be_present, 'a search with no matches says nothing about it'
      expect(hits['data-search-hits']).to eq('0')
    end
  end

  # The layout handout of 02.09.2026 (§3.3, §4, §8).
  describe 'the panel the handout describes' do
    it 'names the three states offen / zur Abrechnung / berechnet' do
      get_list

      words = TimeSession::BILLING_STATUS_FILTERS.map { |v| I18n.t("views.time_sessions.billing_status.#{v}") }
      expect(words).to eq(['offen', 'zur Abrechnung', 'berechnet'])
      # ⚠️ Read through the owner, and asserted here as literals ON PURPOSE: this
      # is the ONE place the words themselves are pinned. §8 calls them
      # non-negotiable, and "abgerechnet" was retired for being ambiguous -- a
      # spec that only checked "some word exists" would let it back in.
      expect(doc.at_css('[data-status-box="billed"]').text).to include('berechnet')
      # ⚠️ Scoped to the row, not the page. "abgerechnet" survives elsewhere as an
      # ordinary German word about a billing GROUP ("die Abrechnung ist bereits
      # abgerechnet"), which §8 does not govern -- it bans it as the STATE's name.
      # Asked of the whole page this caught a translations blob in the layout.
      expect(doc.at_css('#time_status_pills').text).not_to include('abgerechnet')
    end

    it 'draws the three states as checkboxes with their hours, not as pills' do
      get_list

      TimeSession::BILLING_STATUS_FILTERS.each do |value|
        box = doc.at_css(%([data-status-box="#{value}"]))
        expect(box).to be_present, "#{value} has no box"
        # A figure in monospace beside the word: the row is a column of numbers
        # the eye compares.
        expect(box.at_css('.font-mono')).to be_present, "#{value} shows no hours"
      end
    end

    # ⚠️ A bucket with nothing in it keeps its box -- the set is always three --
    # but stops being a link. It is not a thing to click, it is a thing to know
    # is empty.
    it 'greys an empty bucket without removing it' do
      get_list(date_range: 'this_week')

      empty = doc.css('[data-status-state="empty"]')
      expect(empty).not_to be_empty
      expect(empty.first.name).to eq('span'), 'an empty bucket is still a link'
    end

    it 'states the count and the sum above the list, and nothing else' do
      get_list(date_range: 'all')

      summary = doc.at_css('[data-result-summary]').text.squish
      expect(summary).to match(/\A\d+ Zeit(en)? · \d{2}:\d{2}\z/),
                         "the result row says #{summary.inspect}"
    end

    # ⚠️ The sum used to hang on a show_sum parameter, so the row printed 00:00
    # beside an honest count -- worse than not printing it. The parameter is gone
    # entirely now: a switch for something always shown could only confuse.
    it 'states a real sum with nothing asked for' do
      get_list(date_range: 'all')

      expect(doc.at_css('[data-result-summary]').text).not_to include('00:00')
    end

    # ⚠️ BOOKINGS, not rows. The page paginates ROWS -- one subject in one month --
    # and the row counter that used to stand on the right printed exactly that.
    # The result row took its number from the same place at first and called it
    # "Zeiten", which was right only on data where every row holds one booking.
    # Two bookings on one subject in one month is the smallest case that tells
    # the two apart.
    it 'counts bookings, not the rows they are grouped into' do
      meeting = with_tenant { create(:meeting, project: project, organisation: organisation, creator: admin, title: 'Jour fixe') }
      2.times { book(on: Date.current, meeting: meeting, minutes: 30) }

      get_list(date_range: 'all')

      summary = doc.at_css('[data-result-summary]').text.squish
      # Three bookings in total: the one from the outer before block, plus two.
      expect(summary).to start_with('3 Zeiten')
    end

    it 'says the same number beside the search as in the result row' do
      meeting = with_tenant { create(:meeting, project: project, organisation: organisation, creator: admin, title: 'Jour fixe') }
      2.times { book(on: Date.current, meeting: meeting, minutes: 30) }

      get_list(date_range: 'all', search: 'Jour')

      hits = doc.at_css('[data-search-hits]')['data-search-hits']
      expect(doc.at_css('[data-result-summary]').text.squish).to start_with("#{hits} Zeit")
    end

    it 'wears the period alone, without naming the filter' do
      get_list(date_range: '90_days')

      summary = pill(:period).at_css('summary').text.squish
      expect(summary).to eq(TimeSessions::ListPeriod.label('90_days'))
      expect(summary).not_to include(I18n.t('views.organisations.time_sessions.empty_reason.names.period'))
    end
  end

  describe 'what the mobile badge counts' do
    # ⚠️ The badge used to count with its own hand-written list, and by S6 that
    # list was wrong twice over: it knew neither meeting_id, which S6 turned into
    # a real filter, nor creator_id. Two filters narrowed the list without ever
    # reaching the number that says how many do.
    it 'counts a meeting filter' do
      meeting = with_tenant { create(:meeting, project: project, organisation: organisation, creator: admin, title: 'Jour fixe') }
      book(meeting: meeting)

      expect(badge(meeting_id: meeting.id)).to eq('1')
    end

    it 'counts "Nur meine Zeiten"' do
      expect(badge(creator_id: admin.id)).to eq('1')
    end

    it 'counts a project and a period together, not just one of them' do
      expect(badge(project_id_filter: project.id, date_range: 'all')).to eq('2')
    end

    it 'counts nothing on the default address' do
      expect(badge).to eq('0')
    end

    # The number the READER sees, not the helper behind it: a count that is right
    # in Ruby and never reaches the badge is the bug this replaced. Read from
    # data-filter-count, the handle #692 put on the button for the same reason --
    # the number is printed in a span whose only other mark is its styling, and a
    # spec looking for a "2" in the page body finds every 2 on the page.
    def badge(**params)
      get_list(**params)
      doc.at_css('[data-filter-count]')&.[]('data-filter-count')
    end
  end
end
