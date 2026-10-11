# frozen_string_literal: true

require 'rails_helper'

# What: TimeSessions::EmptyReason, the diagnosis behind the time list's empty
#       state. S3 of doc/zeiten_filterzeile_und_stand_plan.md (finding F5).
# Type: Service spec against real rows, because the whole object is a question
#       about the database.
# Why:  The list carries up to seven filters at once and TWO of them are defaults
#       nobody chose (this month, billed hidden), so one generic sentence asked
#       the reader to guess which of seven to touch. What is pinned here is the
#       promise the page makes when it names one: take THIS filter away and rows
#       come back. A wrong name is worse than no name, so both halves matter --
#       naming a filter that would not help, and staying silent about one that
#       would.
RSpec.describe TimeSessions::EmptyReason do
  let(:organisation) { create(:organisation) }
  let(:other_org)    { create(:organisation) }
  let(:admin)        { create(:user) }
  let(:colleague)    { create(:user) }
  let(:project)      { with_tenant { create(:project, organisation: organisation, name: 'WebApp2') } }
  let(:other_project) { with_tenant { create(:project, organisation: organisation, name: 'Nebenprojekt') } }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def book(state: 'without_billing', on: Date.current, project: self.project, creator: admin,
           group: nil, description: 'Arbeit', ticket: nil, organisation: self.organisation)
    ActsAsTenant.with_tenant(organisation) do
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

  # The list's own defaults, spelled out: current month, billed hidden. Every
  # example starts from these because that is what a reader arrives with.
  def default_filters(**overrides)
    {
      start_date: Date.current.beginning_of_month.to_s,
      end_date: Date.current.end_of_month.to_s,
      status_filters: %w[in_billing without_billing]
    }.merge(overrides)
  end

  def reason_for(**filters)
    described_class.call(base_query: TimeSession.all, filters: filters)
  end

  describe 'which filters count as active at all' do
    it 'names none when nothing narrows' do
      book

      reason = reason_for(status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(reason.active).to be_empty
      expect(reason.culprits).to be_empty
    end

    it 'does not count all three status states as a filter' do
      # The filter service treats three of three as no condition at all. Counting
      # it here would offer the reader a pill that changes nothing.
      book(on: 2.months.ago)

      reason = reason_for(**default_filters(status_filters: TimeSession::BILLING_STATUS_FILTERS))

      expect(reason.active).to eq([:period])
    end

    it 'does not count two of three as no filter' do
      book(on: 2.months.ago)

      reason = reason_for(**default_filters)

      expect(reason.active).to contain_exactly(:period, :status)
    end

    it 'does not count a date it cannot parse' do
      # The filter service drops an unparseable bound and logs it. A filter that
      # is not applied must not be blamed. The list is emptied by ONE real
      # filter so the question reaches #narrows? at all: over a query with rows
      # the premise check answers first, and an example that never gets past it
      # passes with a probe that counts 'gestern' as a period (Zweitreview).
      book(project: other_project)

      reason = reason_for(start_date: 'gestern', end_date: '', project_id_filter: project.id,
                          status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(reason.active).to eq([:project])
    end

    it 'does not count a blank value as a filter' do
      # Same shape: one real filter empties the list, the blanks must not join it.
      book(creator: colleague)

      reason = reason_for(project_id_filter: '', ticket_id: nil, search: '', creator_id: admin.id,
                          status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(reason.active).to eq([:creator])
    end

    it 'counts the legacy billing_status as the status filter' do
      # The old single-value param still narrows the list; it belongs to the
      # status unit, or "show all three states" would leave it standing.
      book(state: 'billed')

      reason = reason_for(billing_status: 'unbilled', status_filters: [])

      expect(reason.active).to eq([:status])
      expect(reason.culprits).to eq([:status])
    end
  end

  describe 'naming the culprit' do
    it 'names the period when the only bookings are older' do
      book(on: 2.months.ago)

      reason = reason_for(**default_filters)

      expect(reason.culprits).to eq([:period])
    end

    it 'names the status when the only bookings this month are billed' do
      book(state: 'billed')

      reason = reason_for(**default_filters)

      expect(reason.culprits).to eq([:status])
    end

    it 'names both when either one alone would bring rows back' do
      book(on: 2.months.ago)          # outside the period, inside the status
      book(state: 'billed')           # inside the period, outside the status

      reason = reason_for(**default_filters)

      expect(reason.culprits).to eq(%i[period status])
    end

    it 'names neither when no single filter explains the emptiness' do
      # One booking, old AND billed: dropping the period leaves the status
      # hiding it, dropping the status leaves the period hiding it. Naming
      # either would promise rows that do not come.
      book(state: 'billed', on: 2.months.ago)

      reason = reason_for(**default_filters)

      expect(reason.active).to contain_exactly(:period, :status)
      expect(reason.culprits).to be_empty
    end

    it 'names the pair of a subject and a billing that do not overlap' do
      ticket = with_tenant { create(:ticket, organisation: organisation, project: project, title: 'Kessel flicken') }
      group  = with_tenant { create(:time_session_group, organisation: organisation, name: 'August') }
      book(ticket: ticket)                            # the ticket has hours, in no billing
      book(state: 'in_billing', group: group)         # the billing has hours, on no ticket

      reason = reason_for(ticket_id: ticket.id, time_session_group_id: group.id,
                          status_filters: TimeSession::BILLING_STATUS_FILTERS)

      expect(reason.culprits).to eq(%i[subject billing])
    end

    it 'names the project, the creator and the search each on their own' do
      book(project: other_project, creator: colleague, description: 'Datenbank umgezogen')

      all_states = TimeSession::BILLING_STATUS_FILTERS
      expect(reason_for(project_id_filter: project.id, status_filters: all_states).culprits).to eq([:project])
      expect(reason_for(creator_id: admin.id, status_filters: all_states).culprits).to eq([:creator])
      expect(reason_for(search: 'Kesselhaus', status_filters: all_states).culprits).to eq([:search])
    end

    it 'offers the filters in the order the filter row is read in' do
      # Five bookings, each failing exactly ONE of five filters, so each filter
      # is a culprit on its own. (One booking failing all five was the earlier
      # shape of this example: nothing freed it, culprits was [], and [] is
      # trivially in order, so the assertion compared an empty list with itself.)
      book(on: 2.months.ago, description: 'Kesselhaus gestrichen') # period
      book(project: other_project, description: 'Kesselhaus gestrichen')  # project
      book(state: 'billed', description: 'Kesselhaus gestrichen')         # status
      book(creator: colleague, description: 'Kesselhaus gestrichen')      # creator
      book(description: 'Etwas ganz anderes')                             # search

      # Handed in against the reading order: REMOVABLE decides it, not the
      # order the parameters arrived in.
      reason = reason_for(search: 'Kesselhaus', creator_id: admin.id, project_id_filter: project.id,
                          **default_filters)

      expect(reason.culprits).to eq(%i[period project status creator search])
    end
  end

  describe 'when there is nothing to explain' do
    it 'stays silent while the filtered query has rows' do
      # A page can be empty over a query that is not: ?page=5 of a three-page
      # list. Blaming a filter there would offer a removal that changes nothing
      # about the empty page in front of the reader.
      book

      reason = reason_for(**default_filters)

      expect(reason.active).to be_empty
      expect(reason.culprits).to be_empty
    end
  end

  describe 'the boundary of the period' do
    # n-1 / n / n+1 on the edge the reader is most likely to be caught by. The
    # two examples INSIDE the window assert on `active` and not only on
    # `culprits`: an empty `active` can only come from the premise check, so it
    # says "the query has rows". A bound that dropped its own day would make the
    # list empty and the period both active and guilty, and an assertion on
    # `culprits` alone would not tell those two apart.
    let(:filters) do
      { start_date: Date.new(2026, 9, 1).to_s, end_date: Date.new(2026, 9, 30).to_s,
        status_filters: TimeSession::BILLING_STATUS_FILTERS }
    end

    it 'blames the period for a booking one day before the start' do
      book(on: Date.new(2026, 8, 31))

      expect(reason_for(**filters).culprits).to eq([:period])
    end

    it 'has nothing to explain for a booking on the start itself' do
      book(on: Date.new(2026, 9, 1))

      reason = reason_for(**filters)

      expect(reason.active).to be_empty
      expect(reason.culprits).to be_empty
    end

    it 'has nothing to explain for a booking on the end itself' do
      book(on: Date.new(2026, 9, 30))

      reason = reason_for(**filters)

      expect(reason.active).to be_empty
      expect(reason.culprits).to be_empty
    end

    it 'blames the period for a booking one day after the end' do
      book(on: Date.new(2026, 10, 1))

      expect(reason_for(**filters).culprits).to eq([:period])
    end
  end

  describe 'across tenants' do
    it 'does not let another organisation make a filter look guilty' do
      # The other org holds exactly the booking that would come back if the
      # period were dropped. If the probe saw it, the page would offer a pill
      # that leads to an empty list.
      other_admin = create(:user)
      other_org_project = ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) }
      book(on: 2.months.ago, project: other_org_project, creator: other_admin, organisation: other_org)
      book(state: 'billed', on: 2.months.ago)

      reason = reason_for(**default_filters)

      expect(reason.culprits).to be_empty
    end

    it 'obeys a base query that was already narrowed' do
      # The controller hands in the policy-scoped, smart-folder-resolved base.
      # Anything outside it is not this object's to find: the base holds one
      # booking no single filter frees, while a booking the period alone would
      # free sits OUTSIDE it. A probe that ignored the base would name the period.
      stuck = book(state: 'billed', on: 2.months.ago)
      book(on: 2.months.ago)

      reason = described_class.call(base_query: TimeSession.where(id: stuck.id), filters: default_filters)

      expect(reason.active).to contain_exactly(:period, :status)
      expect(reason.culprits).to be_empty
      expect(described_class.call(base_query: TimeSession.none, filters: default_filters).culprits).to be_empty
    end
  end

  describe 'the keys it speaks in' do
    # The units, their keys and their locale names belong to
    # TimeSessions::ListFilters (spec/models/time_sessions/list_filters_spec.rb).
    it 'are the filters of the one declaration, in its order' do
      expect(described_class::REMOVABLE.keys).to eq(TimeSessions::ListFilters::KEYS)
    end
  end
end
