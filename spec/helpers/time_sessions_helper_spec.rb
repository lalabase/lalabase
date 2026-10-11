# frozen_string_literal: true

require 'rails_helper'

# time_session_subject_presentation is the single source of subject type-knowledge
# for the time list (Gespräche Slice 2) and the billing "Bezug" column, shared by
# the desktop group, the mobile group and the billing subject cell. Testing it in
# isolation locks the icon/label/link/area/nav-label per type — so a drift (e.g.
# the meeting glyph changing on only one partial) is impossible to ship unnoticed,
# and each field breaks its own mutation here.
RSpec.describe TimeSessionsHelper, type: :helper do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:creator)      { create(:user, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  describe '#time_session_subject_presentation' do
    it 'returns nil for a subject-less session (neither ticket nor meeting)' do
      expect(helper.time_session_subject_presentation(nil)).to be_nil
    end

    context 'for a ticket' do
      let(:ticket) { create(:ticket, project: project, creator: creator, title: 'Feature X') }

      # The glyph is the sidebar's ticket glyph, not "no glyph": in the billing
      # "Bezug" column both subject types share one cell, and a glyph on only one
      # of them reads as a flag rather than as a type.
      it 'uses bi-list-task, a #number / title label, the tickets area and the ticket path' do
        parts = helper.time_session_subject_presentation(ticket)

        expect(parts.icon).to eq('bi-list-task')
        expect(parts.label).to eq("##{ticket.number} / Feature X")
        # The two halves separately, so a table column can right-align the
        # reference without taking a regex to the label.
        expect(parts.reference).to eq("##{ticket.number}")
        expect(parts.title).to eq('Feature X')
        expect(parts.read_area).to eq(:tickets)
        expect(parts.path).to eq(organisation_project_ticket_path(organisation, project, ticket))
      end
    end

    context 'for a meeting' do
      let(:meeting) do
        create(:meeting, project: project, organisation: organisation, creator: creator, title: 'Kickoff')
      end

      it 'uses bi-chat-quote, the title as label, the meetings area and the meeting path' do
        parts = helper.time_session_subject_presentation(meeting)

        expect(parts.icon).to eq('bi-chat-quote')
        expect(parts.label).to eq('Kickoff')
        expect(parts.reference).to be_nil
        expect(parts.title).to eq('Kickoff')
        expect(parts.read_area).to eq(:meetings)
        expect(parts.path).to eq(organisation_project_meetings_path(organisation, project, meeting_id: meeting.id))
      end
    end
  end

  # ONE rule for "may this person move this booking into a billing", asked by the
  # row, by the booking under it and by the mobile card. Before it existed the
  # row asked "is any of them unbilled" while the booking also asked "may I
  # assign other people's", so a can_view_all user without admin got a checkbox
  # that selected nothing and a bulk assignment the server then refused whole.
  describe '#time_session_selectable?' do
    let(:owner) { create(:user, organisation: organisation) }
    let(:stranger) { create(:user, organisation: organisation) }
    let(:own_session) { create(:time_session, project: project, organisation: organisation, creator: owner) }
    let(:foreign_session) { create(:time_session, project: project, organisation: organisation, creator: stranger) }

    before { allow(helper).to receive(:current_user).and_return(owner) }

    it 'is true for your own booking' do
      expect(helper.time_session_selectable?(own_session)).to be(true)
    end

    it 'is false for somebody else\'s booking when you may not assign theirs' do
      expect(helper.time_session_selectable?(foreign_session)).to be(false)
    end

    it 'is true for somebody else\'s booking when you may assign theirs' do
      expect(helper.time_session_selectable?(foreign_session, can_bulk_assign_others: true)).to be(true)
    end

    it 'is true for your own booking whether or not you may assign theirs' do
      expect(helper.time_session_selectable?(own_session, can_bulk_assign_others: true)).to be(true)
    end

    # Invoiced beats everything, including the permission: the server refuses
    # such a booking anyway, so a checkbox on it would be a promise it breaks.
    it 'is false for an invoiced booking, even your own and even as an assigner' do
      billed = create(:time_session, project: project, organisation: organisation, creator: owner, billed: true)

      expect(helper.time_session_selectable?(billed)).to be(false)
      expect(helper.time_session_selectable?(billed, can_bulk_assign_others: true)).to be(false)
    end
  end
  # The name a booking answers to in the assignment panel's list of what is about
  # to be taken over, where its row is not around it to identify it.
  describe '#time_session_short_label' do
    let(:ticket) { create(:ticket, project: project, creator: creator, title: 'Feature X') }

    def booking(description:, on: Date.new(2026, 8, 30), subject: ticket)
      create(:time_session, organisation: organisation, project: project, creator: creator,
                            ticket: subject, description: description, occurred_on: on, duration: 30)
    end

    it 'uses the description, which is what tells two bookings apart' do
      expect(helper.time_session_short_label(booking(description: 'Reproduktion und Fix')))
        .to eq('Reproduktion und Fix')
    end

    # THE case this shape exists for: without the date, two undescribed bookings
    # on one ticket read identically in a list whose whole point is saying
    # exactly what is being taken over.
    it 'falls back to the date AND the subject, never the subject alone' do
      first  = booking(description: nil, on: Date.new(2026, 8, 30))
      second = booking(description: '', on: Date.new(2026, 7, 15))

      first_label  = helper.time_session_short_label(first)
      second_label = helper.time_session_short_label(second)

      expect(first_label).to include('Feature X')
      expect(second_label).to include('Feature X')
      expect(first_label).not_to eq(second_label)
    end

    # "   " is not a description. Ruby's nil? would say it is, and the fallback
    # exists precisely so a line is never blank: someone tightening present? to
    # nil? here would print a row of spaces where a name belongs.
    it 'treats a description of nothing but spaces as no description' do
      label = helper.time_session_short_label(booking(description: '   '))

      expect(label).to include('Feature X')
      expect(label.strip).not_to be_empty
    end

    it 'names a booking without any subject rather than leaving the line blank' do
      label = helper.time_session_short_label(booking(description: nil, subject: nil))

      expect(label).to include(I18n.t('views.time_sessions.billing_status.without_subject'))
      expect(label).to include('30.08')
    end
  end
  # The billings the assignment panel offers, and the time each already holds.
  # Both are read through acts_as_tenant, which is invisible in the method body:
  # nothing here says "only this organisation", so nothing here breaks if the
  # declaration is removed from either model. These do.
  describe 'the billings the panel offers' do
    let(:other_org) { create(:organisation) }
    let(:admin) { create(:user) }

    # The real Pundit scope, handed to the view the way a controller hands it
    # over. Stubbing it out would leave the one thing worth checking untested:
    # the totals are org-wide booked time, and the scope is what stops somebody
    # who may see only their own hours from reading everybody's out of them.
    before do
      create(:membership, user: admin, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
      as_user(admin)
    end

    def as_user(user)
      helper.define_singleton_method(:policy_scope) do |scope|
        TimeSessionPolicy::Scope.new(user, scope).resolve
      end
    end

    let!(:own_group) do
      create(:time_session_group, organisation: organisation, creator: creator, name: 'eigene')
    end

    def book(minutes, group:, in_organisation: organisation, in_project: project)
      ActsAsTenant.with_tenant(in_organisation) do
        create(:time_session, organisation: in_organisation, project: in_project,
                              creator: creator, duration: minutes,
                              occurred_on: Date.new(2026, 8, 30), time_session_group: group)
      end
    end

    it 'offers the billings of this organisation' do
      expect(helper.unbilled_time_session_groups).to include(own_group)
    end

    # The leak: another organisation's billing appearing in the list would let
    # somebody assign their hours into it.
    it 'never offers another organisation\'s billing' do
      foreign = ActsAsTenant.with_tenant(other_org) do
        create(:time_session_group, organisation: other_org,
                                    creator: create(:user, organisation: other_org),
                                    name: 'fremde')
      end

      expect(helper.unbilled_time_session_groups).not_to include(foreign)
    end

    # A billed billing is not a target: the panel offers only what can still
    # take time.
    it 'never offers a billing that is already invoiced' do
      billed = create(:time_session_group, organisation: organisation, creator: creator,
                                           name: 'raus', billed: true, invoice_number: 'R-1')

      expect(helper.unbilled_time_session_groups).not_to include(billed)
    end

    it 'sums the minutes a billing already holds' do
      book(45, group: own_group)
      book(30, group: own_group)

      expect(helper.unbilled_time_session_group_minutes[own_group.id]).to eq(75)
    end

    # The default the panel prints as 00:00. Without it a new billing raises or
    # renders an empty cell, and a new billing is the normal case.
    it 'leaves an empty billing out, so the caller\'s default of 0 answers for it' do
      expect(helper.unbilled_time_session_group_minutes).not_to have_key(own_group.id)
      expect(helper.unbilled_time_session_group_minutes.fetch(own_group.id, 0)).to eq(0)
    end

    # The panel prints these totals to everybody who may open the time list. A
    # reader who may see only their own hours must read only their own out of
    # them, exactly as the billing's own entries fragment shows them only their
    # own rows: the number then means "what you can see in there", and the two
    # agree instead of contradicting each other.
    it 'counts only what the reader may see' do
      colleague = create(:user)
      create(:membership, user: colleague, organisation: organisation, active: true)
      create(:time_session_permission, user: colleague, project: project,
                                       can_view_own: true, can_view_all: false)
      book(45, group: own_group)
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session, organisation: organisation, project: project, creator: colleague,
                              duration: 30, occurred_on: Date.new(2026, 8, 30),
                              time_session_group: own_group)
      end

      as_user(colleague)

      expect(helper.unbilled_time_session_group_minutes[own_group.id]).to eq(30)
    end

    # Same leak, one layer down: a foreign booking in the sum would inflate the
    # number the reader uses to decide, without ever being listed.
    it 'counts no time from another organisation' do
      book(45, group: own_group)
      other_project = ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) }
      ActsAsTenant.with_tenant(other_org) do
        create(:time_session, organisation: other_org, project: other_project,
                              creator: create(:user, organisation: other_org),
                              duration: 999, occurred_on: Date.new(2026, 8, 30),
                              time_session_group_id: own_group.id)
      end

      expect(helper.unbilled_time_session_group_minutes[own_group.id]).to eq(45)
    end
  end
  # The page-load fallback address of a filter pill. Its rules are one-liners and
  # each of them is a decision: what removes a key, what a route it must not read
  # from the request, and what an empty query looks like.
  describe '#time_list_filter_url' do
    # The REAL test request, not a double: the method reads two things off it and
    # the route helpers read more, so a double either drifts from the request or
    # has to grow every method Rails happens to call.
    def prepare(query_string, path_parameters = {})
      # Defined on the object rather than stubbed: current_organisation is a
      # controller helper_method, so ActionView::Base does not implement it and a
      # verified double refuses to pretend otherwise.
      org = organisation
      helper.define_singleton_method(:current_organisation) { org }
      helper.request.env['QUERY_STRING'] = query_string
      helper.request.env.delete('action_dispatch.request.query_parameters')
      helper.request.path_parameters = { controller: 'organisations/time_sessions', action: 'index' }
                                       .merge(path_parameters)
    end

    def build(changes = {}, path_parameters: {})
      prepare('date_range=30_days&creator_id=u-1', path_parameters)
      helper.time_list_filter_url(changes)
    end

    it 'keeps what it was not asked to change' do
      expect(build({ 'date_range' => 'year' })).to include('creator_id=u-1')
    end

    it 'sets the key it was asked to change' do
      expect(build({ 'date_range' => 'year' })).to include('date_range=year')
    end

    # Three ways of saying "take it out". nil is the obvious one; the empty
    # string is what a pill sends when it toggles itself off, and an empty array
    # is what the status pills send when the last one is unticked. Tightening
    # blank? to nil? would turn the last two into "status_filters=" in the query.
    [nil, '', []].each do |empty|
      it "removes a key given #{empty.inspect}" do
        expect(build({ 'creator_id' => empty })).not_to include('creator_id')
      end
    end

    it 'keeps a value that only LOOKS empty' do
      expect(build({ 'creator_id' => '0' })).to include('creator_id=0')
    end

    # No trailing "?" on an address with nothing behind it.
    it 'is the bare path when nothing is left to ask for' do
      prepare('')

      expect(helper.time_list_filter_url).to eq(organisation_time_sessions_path(organisation))
    end

    # The route is the organisation list, always: there is no project list any
    # more, and a visitor appending ?project_id=... must not be able to aim
    # somebody's own filter pill anywhere else. A project id in the PATH (the
    # old address) does not change that either.
    it 'is the organisation list even when the path carries a project' do
      url = build({ 'date_range' => 'year' }, path_parameters: { project_id: project.id })

      expect(url).to start_with(organisation_time_sessions_path(organisation))
      expect(url).not_to include("/projects/#{project.id}")
    end

    it 'ignores a project smuggled in through the query' do
      prepare("project_id=#{project.id}")

      expect(helper.time_list_filter_url).to start_with(organisation_time_sessions_path(organisation))
    end
  end

  # ONE change, two shapes (S4 review, 01.09.2026): the Hash time_list_filter_url
  # takes and the pairs lib/query_toggle.js reads. The converter is what keeps a
  # control's href and its owns declaration from disagreeing.
  describe '#time_filter_owns_pairs' do
    it 'clears a nil key with an empty value' do
      expect(helper.time_filter_owns_pairs('creator_id' => nil)).to eq([['creator_id', '']])
    end

    it 'writes a scalar as one pair, as a string' do
      expect(helper.time_filter_owns_pairs('date_range' => 'all', 'page' => 2)).to eq([%w[date_range all], %w[page 2]])
    end

    it 'spreads an array over key[] pairs, one per element' do
      expect(helper.time_filter_owns_pairs('status_filters' => %w[billed in_billing]))
        .to eq([['status_filters[]', 'billed'], ['status_filters[]', 'in_billing']])
    end

    # An empty array clears the key in time_list_filter_url (blank?), so it has
    # to clear it here as well, under the spelling the lib deletes.
    it 'clears an empty array under the key[] spelling' do
      expect(helper.time_filter_owns_pairs('status_filters' => [])).to eq([['status_filters[]', '']])
    end
  end

  describe '#time_period_change' do
    it 'is the period removal with the range in it' do
      expect(helper.time_period_change('year')).to eq('date_range' => 'year', 'start_date' => nil, 'end_date' => nil)
    end
  end

  # What a billing choice takes with it is the empty state's period and status
  # removal, not a list of its own: the two must stay one thing.
  describe '#time_billing_choice_owns' do
    it 'is the period and the status removal in owns shape' do
      removals = TimeSessionsHelper::TIME_FILTER_REMOVALS

      expect(helper.time_billing_choice_owns)
        .to eq(helper.time_filter_owns_pairs(removals.fetch(:period).merge(removals.fetch(:status))))
    end

    it 'opens the period, clears both bounds, switches every state on and drops the legacy param' do
      owns = helper.time_billing_choice_owns

      expect(owns).to include(%w[date_range all], ['start_date', ''], ['end_date', ''], ['billing_status', ''])
      TimeSession::BILLING_STATUS_FILTERS.each { |state| expect(owns).to include(['status_filters[]', state]) }
      expect(owns.map(&:first)).not_to include('time_session_group_id')
    end
  end

  # THE seam from a billing state to a word (S1, 01.09.2026). Before it, nine
  # places knew the three words and five of them disagreed; the structural half
  # of that guard is spec/architecture/billing_state_vocabulary_guard_spec.rb,
  # this is what the seam itself has to answer.
  # The person filter (step 1 of doc/zeiten_weitere_filter_plan.md). A colleague
  # is named only when the controller found them among the people whose time
  # the reader may see (state[:person]); a bare id keeps the neutral name.
  describe '#time_filter_removal_label for the creator' do
    let(:colleague) { create(:user, first_name: 'Anna', last_name: 'Aufwand') }

    it 'names a resolved colleague' do
      label = helper.time_filter_removal_label(:creator, { creator_id: colleague.id, person: colleague })

      expect(label).to eq('Person: Anna Aufwand')
    end

    it 'keeps the neutral name for an id nobody resolved' do
      label = helper.time_filter_removal_label(:creator, { creator_id: colleague.id, person: nil })

      expect(label).to eq(I18n.t('views.organisations.time_sessions.empty_reason.creator_other'))
    end

    it 'stays "Nur meine Zeiten" for the reader\'s own id' do
      label = helper.time_filter_removal_label(:creator, { creator_id: creator.id, creator_mine: true })

      expect(label).to eq(I18n.t('views.organisations.time_sessions.empty_reason.names.creator'))
    end
  end

  describe '#time_filter_addable_kinds' do
    let(:colleague) { create(:user) }

    it 'offers the person once there is someone besides the reader' do
      expect(helper.time_filter_addable_kinds({}, people: [creator, colleague], reader: creator, tags: [], ticket_phase: false)).to eq([:person])
    end

    # The review case: one person, but not the reader.
    it 'offers the person for a single colleague' do
      expect(helper.time_filter_addable_kinds({}, people: [colleague], reader: creator, tags: [], ticket_phase: false)).to eq([:person])
    end

    it 'offers nothing without people' do
      expect(helper.time_filter_addable_kinds({}, people: [], reader: creator, tags: [], ticket_phase: false)).to be_empty
    end

    it 'offers nothing when the only person is the reader' do
      expect(helper.time_filter_addable_kinds({}, people: [creator], reader: creator, tags: [], ticket_phase: false)).to be_empty
    end

    # The tag stands on its own: no people needed, one tag is enough.
    it 'offers the tag for a single tag, even with nobody else to choose' do
      tag = build_stubbed(:tag)

      expect(helper.time_filter_addable_kinds({}, people: [creator], reader: creator, tags: [tag], ticket_phase: false)).to eq([:tag])
    end

    it 'does not offer the tag again while one has a pill' do
      tag = build_stubbed(:tag)

      expect(helper.time_filter_addable_kinds({ tag: tag }, people: [], reader: creator, tags: [tag], ticket_phase: false)).to be_empty
    end

    it 'offers the ticket phase while there is a booking on a ticket' do
      expect(helper.time_filter_addable_kinds({}, people: [], reader: creator, tags: [], ticket_phase: true))
        .to eq([:ticket_phase])
      expect(helper.time_filter_addable_kinds({}, people: [], reader: creator, tags: [], ticket_phase: false))
        .to be_empty
    end

    it 'does not offer the ticket phase again while one has a pill' do
      kinds = helper.time_filter_addable_kinds({ phase: 'done' }, people: [], reader: creator, tags: [],
                                                                  ticket_phase: true)

      expect(kinds).to be_empty
    end

    # Step 3b: a concrete value wears the same pill as a phase.
    it 'does not offer the ticket status again while a value has the pill' do
      choice = TimeSessions::TicketStatusValues::Choice.new(value: 'Fertig', label: 'Fertig')
      kinds = helper.time_filter_addable_kinds({ ticket_status_choice: choice }, people: [], reader: creator,
                                                                                 tags: [], ticket_phase: true)

      expect(kinds).to be_empty
    end

    it 'offers the kinds in the order of the row' do
      expect(helper.time_filter_addable_kinds({}, people: [colleague], reader: creator, tags: [build_stubbed(:tag)],
                                                  ticket_phase: true))
        .to eq(%i[person tag ticket_phase])
    end

    it 'does not offer the person again while one has a pill' do
      expect(helper.time_filter_addable_kinds({ person: colleague }, people: [creator, colleague], reader: creator, tags: [], ticket_phase: false))
        .to be_empty
    end
  end

  # One pill, two parameters (steps 3a and 3b): the value names what is set,
  # the phase first when both were typed, nothing for an unoffered value.
  describe '#time_filter_removal_value for the ticket status' do
    let(:choice) { TimeSessions::TicketStatusValues::Choice.new(value: 'Fertig', label: 'Fertig') }

    it 'names the phase, else the offered value, else nothing' do
      expect(helper.time_filter_removal_value(:ticket_phase, { phase: 'done' }))
        .to eq(TimeSessions::TicketPhase.label('done'))
      expect(helper.time_filter_removal_value(:ticket_phase, { ticket_status_choice: choice })).to eq('Fertig')
      expect(helper.time_filter_removal_value(:ticket_phase, { phase: 'done', ticket_status_choice: choice }))
        .to eq(TimeSessions::TicketPhase.label('done'))
      expect(helper.time_filter_removal_value(:ticket_phase, { ticket_status: 'Fertig' })).to be_nil
    end
  end

  describe '#time_billing_state_label' do
    # Whitelist positive-iteration over the constant: a bucket added without a
    # word fails here, in the one place that turns a state into text.
    TimeSession::BILLING_STATUS_FILTERS.each do |bucket|
      it "answers for #{bucket}, string and symbol alike" do
        expect(helper.time_billing_state_label(bucket)).to be_present
        expect(helper.time_billing_state_label(bucket.to_sym))
          .to eq(helper.time_billing_state_label(bucket))
      end
    end

    # The three words are distinct, which is the whole point of picking them:
    # "Nicht berechnet" and "Ohne Rechnung" used to name different states in
    # different places while reading as the same thing.
    it 'gives the three states three different words' do
      words = TimeSession::BILLING_STATUS_FILTERS.map { |b| helper.time_billing_state_label(b) }

      expect(words.uniq.size).to eq(3)
    end

    it 'says nothing for a subject with nothing booked' do
      expect(helper.time_billing_state_label(:no_sessions)).to be_nil
      expect(helper.time_billing_state_label(nil)).to be_nil
    end

    # A mixed row says how far it got, and falls back to the plain word when
    # there is no share to name — 0 is a share, nil is not.
    it 'names the share for a mixed subject' do
      expect(helper.time_billing_state_label(:mixed, percent: 61)).to include('61')
      expect(helper.time_billing_state_label(:mixed, percent: 0)).to include('0')
      expect(helper.time_billing_state_label(:mixed))
        .to eq(I18n.t('views.time_sessions.billing_status.mixed'))
    end

    it 'answers in English on an English page' do
      I18n.with_locale(:en) do
        expect(helper.time_billing_state_label('without_billing'))
          .to eq(I18n.t('views.time_sessions.billing_status.without_billing', locale: :en, fallback: false))
      end
    end
  end

  # The one clock spelling for compared durations (header chip, capture
  # popover). The examples sit on the two arithmetic seams: the /60 split and
  # the %02d minute padding — flip either and one of these goes red.
  describe '#time_clock_label' do
    it 'pads minutes to two digits below the first hour' do
      expect(helper.time_clock_label(59)).to eq('0:59')
    end

    it 'rolls 60 minutes into the hour (boundary)' do
      expect(helper.time_clock_label(60)).to eq('1:00')
    end

    it 'keeps single-digit minutes padded above the hour (boundary + padding)' do
      expect(helper.time_clock_label(61)).to eq('1:01')
    end

    it 'renders the documented example 108 -> 1:48 without a leading hour zero' do
      expect(helper.time_clock_label(108)).to eq('1:48')
    end

    it 'answers 0:00 for zero and for nil (to_i contract of the callers)' do
      expect(helper.time_clock_label(0)).to eq('0:00')
      expect(helper.time_clock_label(nil)).to eq('0:00')
    end

    it 'grows the hour field past two digits instead of clamping' do
      expect(helper.time_clock_label(600)).to eq('10:00')
    end
  end
end
