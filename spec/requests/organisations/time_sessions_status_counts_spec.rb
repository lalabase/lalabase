# frozen_string_literal: true

require 'rails_helper'

# What: Each status pill of the time list carries the HOURS in that state.
#       S2 of doc/zeiten_filterzeile_und_stand_plan.md.
# Type: Request spec over the rendered index, plus the list it promises.
# Why:  A figure next to a filter makes a promise about what a click delivers, and
#       one nobody can trust is worse than none (F4). The rule is that it runs
#       under every active filter EXCEPT the status filter. Computed WITH it, a
#       page shows "05:00" beside a pill it has just filtered away; computed with
#       NO filters, it shows three figures beside an empty list, which is what the
#       design review reproduced.
#
#       Hours rather than a count of bookings (decision of 01.09.2026): the page
#       counts ROWS in its footer ("6 Zeilen", one subject in one month), so a
#       bare booking count beside it read as a second version of the same number
#       and disagreed with it. Hours cannot be confused with a row count, and they
#       ADD UP: minutes belong to exactly one state.
#
#       Two promises are pinned end to end, and nothing weaker would have caught
#       the mock:
#         * a pill equals the sum the list shows when that pill is the only status
#         * the active pills together equal the sum box under the filter
RSpec.describe 'Time list: status counts', type: :request do
  let(:organisation) { create(:organisation) }
  let(:other_org)    { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:project)      { with_tenant { create(:project, organisation: organisation, name: 'WebApp2') } }
  let(:other_project) { with_tenant { create(:project, organisation: organisation, name: 'Nebenprojekt') } }

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

  # One booking, in one state, on one day.
  # Returns the booking, so an example can delete the one it made.
  def book(state, on: Date.current, project: self.project, description: 'Arbeit')
    with_tenant do
      attrs = { organisation: organisation, project: project, creator: admin, duration: 60,
                occurred_on: on, description: description }
      case state
      when 'billed'
        create(:time_session, **attrs, billed: true,
                                       time_session_group: create(:time_session_group, :billed, organisation: organisation))
      when 'in_billing'
        create(:time_session, **attrs,
                              time_session_group: create(:time_session_group, organisation: organisation))
      else
        create(:time_session, **attrs)
      end
    end
  end

  # A local, NOT a constant. A constant assigned in an RSpec block lands on
  # Object, and Object is an ancestor of everything: writing `ALL = ...` here made
  # Lalabase::Tools::Registry.const_defined?(:ALL) answer true and turned a guard
  # three directories away red, but only once this file joined the CI list and
  # changed the load order. RuboCop's Lint/ConstantDefinitionInBlock says the same.
  all_states = TimeSession::BILLING_STATUS_FILTERS

  def get_list(**params)
    get organisation_time_sessions_path(organisation, **params)
    expect(response).to have_http_status(:ok)
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  # The pill row, read back as { bucket => minutes } from what a reader sees.
  #
  # Anchored inside #time_status_pills and on the pill's own label span, not on an
  # aria-label: an empty pill is a <span> with no role, and aria-label on such an
  # element is invalid per ARIA 1.2, so the markup says the unit in sr-only text
  # instead. The oracle has to read what the markup actually is.
  def pill_minutes(scope = doc)
    TimeSession::BILLING_STATUS_FILTERS.index_with do |bucket|
      hours, minutes = pill_for(bucket, scope).text[/(\d+):(\d\d)/, 0].to_s.split(':')
      (hours.to_i * 60) + minutes.to_i
    end
  end

  def pill_for(bucket, scope = doc)
    word = I18n.t("views.time_sessions.billing_status.#{bucket}")
    pills = scope.css('#time_status_pills > a, #time_status_pills > span')
    pills = scope.css('a, span') if pills.empty?
    pills.find { |n| n.css('span').any? { |inner| inner.text.strip == word } }
  end

  # The pill row as it arrives inside a frame answer's replace instruction.
  def replacement_pills
    Nokogiri::HTML(doc.css('turbo-stream[target="time_status_pills"] template').inner_html)
  end

  # What the list itself says the filtered time adds up to.
  #
  # ⚠️ Read from the RESULT ROW since 02.09.2026. It used to be a boxed total
  # above the table behind a show_sum parameter; that box is gone, and the
  # parameter with it, because the row states the sum on every render. The old
  # reader answered 0 for every page once the box left, which would have made
  # every comparison below trivially true -- the pills' figures agreeing with a
  # zero they also produce.
  #
  # Anchored on the row's own handle, not on a label and its sibling: every
  # ancestor contains that text too, and the outer ones contain every duration
  # on the page, so a looser selector reads back the first booking's duration
  # and calls it the sum.
  def sum_box_minutes
    summary = doc.at_css('[data-result-summary]')
    return 0 if summary.nil?

    hours, minutes = summary.text[/(\d+):(\d\d)/, 0].to_s.split(':')
    (hours.to_i * 60) + minutes.to_i
  end

  # What the list itself adds up to for one status, everything else held equal.
  # Read off the page's own sum box, not recomputed here: the point is that the
  # two figures a reader sees agree, so both have to come from the page.
  def sum_shown(**params)
    get_list(**params, date_range: params[:date_range] || 'all')
    sum_box_minutes
  end

  describe 'the figure a pill shows' do
    before do
      2.times { book('without_billing') }
      3.times { book('in_billing') }
      book('billed')
    end

    it 'shows the hours in each state' do
      get_list(date_range: 'all')

      expect(pill_minutes).to eq('without_billing' => 120, 'in_billing' => 180, 'billed' => 60)
    end

    # PROMISE 1. Each pill is followed to the list it stands for, and the list is
    # asked with its own sum box rather than recomputed here.
    all_states.each do |bucket|
      it "matches the sum the list shows when #{bucket} is the only status" do
        get_list(date_range: 'all')
        promised = pill_minutes.fetch(bucket)

        expect(sum_shown(status_filters: [bucket])).to eq(promised)
      end
    end

    # PROMISE 2, the one that decided hours over a count of bookings: minutes
    # belong to exactly one state, so the ACTIVE pills add up to the sum box.
    # Neither a booking count nor a row count can make this promise -- rows would
    # overlap, because one row can hold two states.
    it 'adds up: the active pills together are the sum under the list' do
      get_list(date_range: 'all', status_filters: %w[without_billing in_billing])
      active = pill_minutes.values_at('without_billing', 'in_billing').sum

      expect(active).to eq(sum_box_minutes)
      expect(active).to eq(300)
    end

    it 'adds up with all three active, too' do
      get_list(date_range: 'all', status_filters: all_states)

      expect(pill_minutes.values.sum).to eq(sum_box_minutes)
    end

    # The join the full-text search adds is where a naive SUM double counts. The
    # sum box goes out of its way to avoid that (an id subquery, because
    # SUM(DISTINCT duration) collapses equal values); the pills must land on the
    # same figure anyway. Two bookings of 60 are exactly the case that breaks.
    it 'adds up while a search is joining tables' do
      get_list(date_range: 'all', search: 'Arbeit', status_filters: all_states)

      expect(pill_minutes.values.sum).to eq(sum_box_minutes)
      expect(sum_box_minutes).to eq(360)
    end

    # The default view hides 'billed'. Its figure must still be the truth about
    # the org, or the pill that offers to reveal it would say 00:00 and lie.
    it 'shows a state that the current filter hides' do
      get_list(date_range: 'all', status_filters: %w[without_billing])

      expect(pill_minutes).to eq('without_billing' => 120, 'in_billing' => 180, 'billed' => 60)
    end

    # The counterexample from the review: three figures beside an empty list.
    it 'does not keep its figures when another filter empties the list' do
      get_list(date_range: 'all', search: 'gibtesnichtimtext')

      expect(pill_minutes.values).to all(eq(0))
    end
  end

  describe 'the other filters a count has to obey' do
    it 'obeys the period' do
      book('without_billing', on: Date.new(2026, 3, 10))
      book('without_billing', on: Date.new(2026, 6, 10))

      get_list(date_range: 'custom', start_date: '2026-03-01', end_date: '2026-03-31')

      expect(pill_minutes.fetch('without_billing')).to eq(60)
    end

    # n-1 / n / n+1 on the period edge: the end bound is INCLUSIVE, which is the
    # bug TimeSessionFilterService#parse_bound exists for. A count that used a
    # different bound than the list would be off by exactly the last day.
    it 'includes the last day of the period, like the list does' do
      book('without_billing', on: Date.new(2026, 3, 30))
      book('without_billing', on: Date.new(2026, 3, 31))
      book('without_billing', on: Date.new(2026, 4, 1))

      get_list(date_range: 'custom', start_date: '2026-03-01', end_date: '2026-03-31')

      expect(pill_minutes.fetch('without_billing')).to eq(120)
      expect(sum_shown(date_range: 'custom', start_date: '2026-03-01', end_date: '2026-03-31')).to eq(120)
    end

    it 'obeys the project' do
      book('without_billing')
      book('without_billing', project: other_project)

      get_list(date_range: 'all', project_id_filter: project.id)

      expect(pill_minutes.fetch('without_billing')).to eq(60)
    end

    it 'obeys the subject' do
      ticket = with_tenant { create(:ticket, organisation: organisation, project: project) }
      with_tenant do
        create(:time_session, organisation: organisation, project: project, creator: admin,
                              duration: 60, ticket: ticket)
      end
      book('without_billing')

      get_list(date_range: 'all', ticket_id: ticket.id)

      # This one used to be guarded twice over: find_time_sessions narrowed the
      # base query by params[:ticket_id] before the filter service ever saw it,
      # so the count obeyed the subject even if it skipped the service entirely.
      # The duplicate came out with S3 (the empty state has to be able to switch
      # the subject off), so a green here now really is the service path.
      expect(pill_minutes.fetch('without_billing')).to eq(60)
    end

    it 'obeys the full-text search' do
      book('without_billing', description: 'Datenbank umgezogen')
      book('without_billing', description: 'Etwas ganz anderes')

      get_list(date_range: 'all', search: 'Datenbank')

      expect(pill_minutes.fetch('without_billing')).to eq(60)
    end

    it 'obeys a chosen billing' do
      group = with_tenant { create(:time_session_group, organisation: organisation, name: 'August') }
      with_tenant do
        create(:time_session, organisation: organisation, project: project, creator: admin,
                              duration: 60, time_session_group: group)
      end
      book('in_billing')

      get_list(date_range: 'all', time_session_group_id: group.id)

      expect(pill_minutes.fetch('in_billing')).to eq(60)
    end

    it 'obeys "only my times"' do
      colleague = create(:user)
      with_tenant do
        create(:membership, user: colleague, organisation: organisation, role: admin_role, active: true)
        create(:time_session, organisation: organisation, project: project, creator: colleague, duration: 60)
      end
      book('without_billing')

      get_list(date_range: 'all', creator_id: admin.id)

      expect(pill_minutes.fetch('without_billing')).to eq(60)
    end
  end

  # Multi-tenancy: the count runs on the policy-scoped base query, so it can only
  # ever count what the reader may see. An org-wide COUNT would leak the size of
  # somebody else's books through a number.
  describe 'across organisations' do
    it 'counts nothing from another organisation' do
      book('without_billing')
      ActsAsTenant.with_tenant(other_org) do
        foreign_project = create(:project, organisation: other_org)
        foreign_user = create(:user)
        create(:membership, user: foreign_user, organisation: other_org, active: true)
        3.times do
          create(:time_session, organisation: other_org, project: foreign_project,
                                creator: foreign_user, duration: 60)
        end
      end

      get_list(date_range: 'all')

      expect(pill_minutes.fetch('without_billing')).to eq(60)
    end
  end

  describe 'a state with nothing in it' do
    it 'offers no click, and says why' do
      book('without_billing')

      get_list(date_range: 'all')

      expect(pill_for('billed').name).to eq('span')
      # The reason is sr-only text, not a title: a title is only reachable with a
      # mouse, and this is the sentence that explains why the pill is dead.
      expect(pill_for('billed').css('.sr-only').text)
        .to include(I18n.t('views.organisations.time_sessions.index.filter_status_none_here'))
    end

    it 'still shows the state that HAS something as a link' do
      book('without_billing')

      get_list(date_range: 'all')

      expect(pill_for('without_billing').name).to eq('a')
    end

    # The trap this avoids: a filter that emptied the list must stay clickable,
    # or the reader can see nothing and undo nothing. An ACTIVE pill at zero is
    # the way back, so it keeps its link.
    it 'keeps an ACTIVE pill clickable at zero, so the filter can be undone' do
      book('without_billing')

      get_list(date_range: 'all', status_filters: %w[billed])

      expect(pill_for('billed').name).to eq('a')
      expect(pill_minutes.fetch('billed')).to eq(0)
    end
  end

  # ⚠️ THE structural promise, and the one a plain request spec cannot see.
  #
  # The pills sit OUTSIDE time_sessions_list_frame, and the search box, the
  # selects and the custom date fields all target that frame. Turbo swaps the
  # frame in the BROWSER and leaves the rest of the page alone, so a request spec
  # that reads the whole response body is green whatever happens: the server
  # always renders the fresh pills somewhere in the page it returns.
  #
  # What can be checked is whether the answer carries an instruction to update
  # them. Without the turbo-stream element at the foot of _index_table, a search
  # that matches nothing leaves three figures standing over an empty list, which
  # is precisely the mock this whole slice exists to prevent.
  describe 'a frame answer' do
    before { 2.times { book('without_billing') } }

    def frame_get(**params)
      get organisation_time_sessions_path(organisation, **params),
          headers: { 'Turbo-Frame' => 'time_sessions_list_frame' }
      expect(response).to have_http_status(:ok)
    end

    it 'carries an instruction to replace the status pills' do
      frame_get(date_range: 'all', search: 'gibtesnichtimtext')

      stream = doc.css('turbo-stream[action="replace"][target="time_status_pills"]')
      expect(stream).not_to be_empty
    end

    # ⚠️ The one that actually pins the fix, learnt the hard way: the first
    # version of this partial put the instruction AFTER </turbo-frame>. On a frame
    # navigation Turbo takes the matching frame out of the answer and throws the
    # rest away, so the element was in the response, this spec was green, and in a
    # real browser the figures never moved. "It is in the body" is not the
    # question; "does it travel with the frame" is.
    it 'puts the instruction INSIDE the frame, which is the only place it travels from' do
      frame_get(date_range: 'all', search: 'gibtesnichtimtext')

      inside = doc.css('turbo-frame#time_sessions_list_frame turbo-stream[target="time_status_pills"]')
      expect(inside).not_to be_empty
    end

    it 'puts the figures OF THAT ANSWER into the instruction, not the ones the page opened with' do
      frame_get(date_range: 'all', search: 'gibtesnichtimtext')

      expect(pill_minutes(replacement_pills).values).to all(eq(0))
    end

    # The other half of the same bug: `state` is decided once per render. A pill
    # that was empty when the page loaded stayed a dead <span>, so a search whose
    # only hits were billed could not be reached at all -- the exact case the
    # "an active pill stays clickable" rule was written for.
    it 'can turn a pill that was empty on load back into a link' do
      book('billed', description: 'Rechnungsposten')

      frame_get(date_range: 'all', search: 'Rechnungsposten')

      expect(pill_for('billed', replacement_pills).name).to eq('a')
      expect(pill_minutes(replacement_pills).fetch('billed')).to eq(60)
    end

    # A full page load renders the pills through the form above the list, so the
    # instruction would only replace them with themselves.
    it 'is not sent with a full page load' do
      get_list(date_range: 'all')

      expect(doc.css('turbo-stream[target="time_status_pills"]')).to be_empty
    end
  end

  # The count runs on the policy-scoped base query. The cross-org example above
  # cannot see that: acts_as_tenant alone keeps another ORGANISATION out, so it
  # stays green even if policy_scope fell out of the counting path. Someone who
  # may see only their OWN hours is the case that needs the scope.
  describe 'a reader who may see only their own time' do
    let(:member_role) { create(:role, organisation: organisation) }
    let(:colleague)   { create(:user) }

    # can_view_own, the permission shape time_sessions_visibility_spec pins.
    it 'counts only what that reader may see' do
      with_tenant do
        create(:membership, user: colleague, organisation: organisation, role: member_role, active: true)
        create(:time_session_permission, user: colleague, project: project,
                                         can_view_own: true, can_view_all: false)
        3.times do
          create(:time_session, organisation: organisation, project: project, creator: admin, duration: 60)
        end
        create(:time_session, organisation: organisation, project: project, creator: colleague, duration: 60)
      end

      sign_in colleague
      get_list(date_range: 'all')

      expect(pill_minutes.fetch('without_billing')).to eq(60)
    end
  end

  # The controller drops billing_status along with status_filters, and says so in
  # a comment. No example sent the legacy parameter, so putting it back was free.
  it 'ignores the legacy billing_status parameter when computing the figures' do
    2.times { book('without_billing') }
    book('billed')

    get_list(date_range: 'all', billing_status: 'billed')

    expect(pill_minutes).to eq('without_billing' => 120, 'in_billing' => 0, 'billed' => 60)
  end

  # Emptiness asks the BOOKING count, not the minutes. With every fixture at 60
  # minutes the two are interchangeable and swapping them stays green.
  it 'decides emptiness on bookings, not on minutes' do
    with_tenant do
      create(:time_session, organisation: organisation, project: project, creator: admin,
                            duration: 30, occurred_on: Date.current)
    end

    get_list(date_range: 'all')

    expect(pill_minutes.fetch('without_billing')).to eq(30)
    expect(pill_for('without_billing').name).to eq('a')
  end

  # status_filters[] arrives from the query string. Taken raw, a junk value
  # activated no pill while the list stayed unfiltered (the filter service only
  # looks for the three names it knows), and _filter_selects carried it along on
  # every submit. Duplicates were the same hole from the other side: four entries
  # make `filters.size < 3` false and the whole status filter drops out.
  describe 'a status_filters value that is not one of the three' do
    before do
      2.times { book('without_billing') }
      book('billed')
    end

    it 'is ignored, and the list falls back to the default statuses' do
      get_list(date_range: 'all', status_filters: %w[foo])

      expect(pill_minutes).to eq('without_billing' => 120, 'in_billing' => 0, 'billed' => 60)
      expect(sum_shown(status_filters: %w[foo])).to eq(120)
    end

    it 'does not let a duplicate switch the filter off' do
      get_list(date_range: 'all',
               status_filters: %w[without_billing without_billing in_billing billed])

      expect(sum_box_minutes).to eq(180)
    end
  end

  # Deleting a booking changes every figure the page carries. The answer used to
  # be turbo_stream.remove on the row alone, which leaves the pills, the row count
  # and the sum standing at their pre-delete values: they all live outside the row.
  # The list now gets the same repaint update already gives it.
  describe 'deleting a booking from the list' do
    it 'answers with a repaint, so the figures outside the row follow' do
      session = book('without_billing')
      book('without_billing')

      delete organisation_time_session_path(organisation, session, context: 'index_page'),
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('action="refresh"')
    end

    # The ticket page answers differently on purpose and must keep doing so.
    it 'still answers the ticket page with its own streams' do
      ticket = with_tenant { create(:ticket, organisation: organisation, project: project) }
      session = with_tenant do
        create(:time_session, organisation: organisation, project: project, creator: admin,
                              duration: 60, ticket: ticket, occurred_on: Date.current)
      end

      delete organisation_time_session_path(organisation, session, context: 'ticket'),
             headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('action="refresh"')
    end
  end

  # The counts are ONE grouped query, not one per state and not one per row.
  # Matched on the GROUP BY, not on "COUNT plus a group_id predicate": the
  # pagination row-count carries both of those inside its subquery and would make
  # this example pass at two queries and fail at one.
  it 'costs a single extra query, whatever the number of bookings' do
    5.times { book('without_billing') }
    5.times { book('in_billing') }

    statements = []
    subscriber = lambda do |_n, _s, _f, _i, payload|
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])

      sql = payload[:sql].to_s
      statements << sql if sql.include?('GROUP BY "time_sessions"."billed"') && sql.include?('COUNT(*)')
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { get_list(date_range: 'all') }

    expect(statements.size).to eq(1)
  end
end
