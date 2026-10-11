# frozen_string_literal: true

require 'rails_helper'

# The artefact lane's first inhabitant (plan §8.1, S3c T3). What is tested here is
# the RIGHTS BOUNDARY and the honesty of the numbers, because every parameter this
# object sees can be typed into an address bar.
RSpec.describe Assistant::Panels::TimeReport do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:colleague) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
    create(:membership, user: colleague, organisation: organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  def permit(view_all:, for_user: user, on: project)
    create(:time_session_permission, user: for_user, project: on,
                                     can_view_own: true, can_view_all: view_all)
  end

  def book(minutes:, creator: user, billed: false, grouped: false, on: project, occurred_on: 2.days.ago)
    group = grouped ? create(:time_session_group, organisation: organisation) : nil
    create(:time_session, project: on, organisation: organisation, creator: creator,
                          duration: minutes, billed: billed, time_session_group_id: group&.id,
                          occurred_on: occurred_on)
  end

  def call(params)
    described_class.call(user: user, organisation: organisation, params: params)
  end

  describe 'the rights boundary' do
    it 'refuses a project without a persisted time permission' do
      book(minutes: 60)

      panel = call(project_id: project.id)

      expect(panel.available?).to be(false)
      expect(panel.rows).to be_nil
    end

    it 'refuses a project of another organisation even for a member of both' do
      other_org = create(:organisation)
      other_project = nil
      # Created INSIDE the other tenant on purpose: acts_as_tenant stamps the
      # current tenant on a new record, so building it out here would quietly
      # produce a second project of THIS organisation and the test would pass
      # without ever crossing the border it claims to guard.
      ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        create(:membership, user: user, organisation: other_org)
        create(:time_session_permission, user: user, project: other_project,
                                         can_view_own: true, can_view_all: true)
      end
      expect(other_project.organisation_id).to eq(other_org.id)

      panel = call(project_id: other_project.id)

      expect(panel.available?).to be(false)
    end

    it 'answers a missing project exactly like a forbidden one (no existence oracle)' do
      missing = call(project_id: SecureRandom.uuid)
      book(minutes: 60)
      forbidden = call(project_id: project.id)

      expect([missing.available?, forbidden.available?]).to eq([false, false])
      expect(missing.project).to be_nil
      expect(forbidden.project).to eq(project)
    end

    it 'shows only the reader own bookings under the own tier' do
      permit(view_all: false)
      book(minutes: 60, creator: user)
      book(minutes: 120, creator: colleague)

      panel = call(project_id: project.id)

      expect(panel.tier).to eq(:own)
      expect(panel.rows.map(&:creator_id)).to eq([user.id])
      expect(panel.totals['without_billing'][:minutes]).to eq(60)
    end

    it 'shows every booking under the all tier' do
      permit(view_all: true)
      book(minutes: 60, creator: user)
      book(minutes: 120, creator: colleague)

      panel = call(project_id: project.id)

      expect(panel.tier).to eq(:all)
      expect(panel.totals['without_billing'][:minutes]).to eq(180)
    end

    it 'never widens the own tier through a creator filter naming somebody else' do
      permit(view_all: false)
      book(minutes: 60, creator: user)
      book(minutes: 120, creator: colleague)

      panel = call(project_id: project.id, creator_id: colleague.id)

      expect(panel.rows).to be_empty
      expect(panel.totals.values.sum { |t| t[:minutes] }).to eq(0)
    end
  end

  # Kategorie 2/5: the tier decides what a reader sees, and the rule has THREE
  # values. Iterating the constant means a fourth tier cannot be added without a
  # decision here -- and `available?` names the tiers that may see something, so a
  # new one is refused until somebody says otherwise.
  describe 'every tier of TimeSessions::ViewingScope' do
    let(:expectations) do
      { all: true, own: true, none: false }
    end

    it 'covers every tier the constant knows' do
      expect(expectations.keys).to match_array(TimeSessions::ViewingScope::TIERS)
    end

    TimeSessions::ViewingScope::TIERS.each do |tier|
      it "answers available? correctly for the #{tier} tier" do
        case tier
        when :all then permit(view_all: true)
        when :own then permit(view_all: false)
        end
        book(minutes: 60)

        expect(call(project_id: project.id).available?).to be(expectations.fetch(tier))
      end
    end
  end

  # Kategorie 5: the panel is addressed by project, and every neighbour is a way
  # for rows to leak in.
  describe 'the scope of the rows' do
    before { permit(view_all: true) }

    it 'never shows a booking of another project of the same organisation' do
      other = create(:project, organisation: organisation)
      ActsAsTenant.with_tenant(organisation) do
        create(:time_session_permission, user: user, project: other,
                                         can_view_own: true, can_view_all: true)
      end
      book(minutes: 60)
      book(minutes: 120, on: other)

      panel = call(project_id: project.id)

      expect(panel.row_count).to eq(1)
      expect(panel.totals['without_billing'][:minutes]).to eq(60)
    end

    it 'never shows a soft-deleted booking, in the list or in the sums' do
      book(minutes: 60)
      book(minutes: 120).update!(deleted_at: Time.current)

      panel = call(project_id: project.id)

      expect(panel.row_count).to eq(1)
      expect(panel.totals['without_billing'][:minutes]).to eq(60)
    end

    # "Nothing found" and "not allowed to look" are different answers and must not
    # collapse into one: the first gets a report saying so, the second a refusal.
    it 'is available with an empty list when the filters match nothing' do
      panel = call(project_id: project.id, start_date: '2000-01-01', end_date: '2000-01-02')

      expect(panel).to be_available
      expect(panel.rows).to be_empty
      expect(panel.totals.values.sum { |t| t[:minutes] }).to eq(0)
    end
  end

  # Kategorie 2/7: exactly four filter keys are honoured, and everything else the
  # address carries is dropped. The mutation this kills: handing the raw params
  # through, at which point `billing_status` or `project_id_filter` would silently
  # narrow (or widen) a report nobody asked to narrow.
  describe 'the filter whitelist' do
    before { permit(view_all: true) }

    it 'covers every key of AssistantArtefactsHelper::REPORT_FILTER_KEYS' do
      expect(AssistantArtefactsHelper::REPORT_FILTER_KEYS)
        .to match_array(%i[start_date end_date creator_id ticket_id])
    end

    it 'ignores a filter key it does not know, however plausible it looks' do
      book(minutes: 60, billed: true)

      panel = call(project_id: project.id, billing_status: 'without_billing',
                   project_id_filter: SecureRandom.uuid, search: 'nope')

      expect(panel.row_count).to eq(1)
      expect(panel.filters.keys).to be_empty
    end

    it 'applies a ticket filter that is a uuid' do
      ticket = create(:ticket, project: project, organisation: organisation)
      book(minutes: 60)
      booked_on_ticket = book(minutes: 30)
      booked_on_ticket.update!(ticket_id: ticket.id)

      panel = call(project_id: project.id, ticket_id: ticket.id)

      expect(panel.rows.map(&:id)).to eq([booked_on_ticket.id])
      expect(panel.filters[:ticket_id]).to eq(ticket.id)
    end

    it 'ignores a ticket filter that is not a uuid instead of narrowing to nothing' do
      book(minutes: 60)

      panel = call(project_id: project.id, ticket_id: '187')

      expect(panel.row_count).to eq(1)
      expect(panel.filters).not_to have_key(:ticket_id)
    end
  end

  # Kategorie 3: the dates are INCLUSIVE on both ends (TimeSessionFilterService
  # widens them to beginning_of_day / end_of_day). A booking on the last day of a
  # billing period is exactly the row somebody would notice missing.
  describe 'the date range (boundary)' do
    before { permit(view_all: true) }

    let(:from) { Date.new(2026, 5, 10) }
    let(:upto) { Date.new(2026, 5, 20) }

    def panel_for_range
      call(project_id: project.id, start_date: from.to_s, end_date: upto.to_s)
    end

    it 'excludes the day before the range' do
      book(minutes: 60, occurred_on: from - 1.day)

      expect(panel_for_range.row_count).to eq(0)
    end

    it 'includes the first day of the range, at its very beginning' do
      book(minutes: 60, occurred_on: from.beginning_of_day)

      expect(panel_for_range.row_count).to eq(1)
    end

    it 'includes the last day of the range, up to its very end' do
      book(minutes: 60, occurred_on: upto.end_of_day - 1.second)

      expect(panel_for_range.row_count).to eq(1)
    end

    it 'excludes the day after the range' do
      book(minutes: 60, occurred_on: upto + 1.day)

      expect(panel_for_range.row_count).to eq(0)
    end
  end

  # The reason TimeSessions::BucketTotals was extracted. If somebody re-implements
  # either side, the two answers to one question start to differ, and the panel
  # sits directly under the sentence it is supposed to explain.
  describe 'agreement with the chat tool' do
    it 'reports the same minutes per bucket as SummarizeTimeSessions for the same project' do
      permit(view_all: true)
      book(minutes: 60, billed: true)
      book(minutes: 30, grouped: true)
      book(minutes: 15)

      context = Lalabase::Tools::Context.new(project: project, actor: user)
      tool = JSON.parse(Lalabase::Tools::SummarizeTimeSessions.execute(args: {}, context: context).content)
      panel = call(project_id: project.id)

      TimeSession::BILLING_STATUS_FILTERS.each do |bucket|
        expect(panel.totals[bucket][:minutes]).to eq(tool['buckets'][bucket]['minutes']),
                                                  "bucket #{bucket} disagrees with the chat tool"
      end
    end
  end

  describe 'the numbers' do
    before { permit(view_all: true) }

    it 'splits the three billing buckets' do
      book(minutes: 60, billed: true)
      book(minutes: 30, grouped: true)
      book(minutes: 15)

      panel = call(project_id: project.id)

      expect(panel.totals['billed'][:minutes]).to eq(60)
      expect(panel.totals['in_billing'][:minutes]).to eq(30)
      expect(panel.totals['without_billing'][:minutes]).to eq(15)
    end

    # Kategorie 3, n-1 / n / n+1 around the cap itself. The first version of this
    # example used a cap of 2 against 3 rows, i.e. far outside the boundary -- that
    # survives every off-by-one (`>` vs `>=`, `limit(N)` vs `limit(N - 1)`).
    describe 'the row cap (boundary)' do
      before { stub_const("#{described_class}::ROW_LIMIT", 3) }

      it 'shows everything and is not truncated one below the cap' do
        2.times { book(minutes: 60) }

        panel = call(project_id: project.id)

        expect(panel.rows.size).to eq(2)
        expect(panel).not_to be_truncated
      end

      it 'shows everything and is NOT truncated exactly AT the cap' do
        3.times { book(minutes: 60) }

        panel = call(project_id: project.id)

        expect(panel.rows.size).to eq(3)
        expect(panel).not_to be_truncated
      end

      it 'caps and says so one above the cap, while the sums stay complete' do
        4.times { book(minutes: 60) }

        panel = call(project_id: project.id)

        expect(panel.rows.size).to eq(3)
        expect(panel.row_count).to eq(4)
        expect(panel).to be_truncated
        expect(panel.totals['without_billing'][:minutes]).to eq(240)
      end
    end

    # Kategorie 4: the cap is a promise to the reader (the view prints it), not an
    # implementation detail somebody may quietly halve.
    it 'pins the shipped cap at 100' do
      expect(described_class::ROW_LIMIT).to eq(100)
    end

    it 'applies a date range that parses' do
      book(minutes: 60, occurred_on: Date.new(2026, 3, 10))
      book(minutes: 120, occurred_on: Date.new(2026, 5, 10))

      panel = call(project_id: project.id, start_date: '2026-05-01', end_date: '2026-05-31')

      expect(panel.row_count).to eq(1)
      expect(panel.filters[:start_date]).to eq('2026-05-01')
    end

    # The trap this guards: TimeSessionFilterService drops a malformed date without
    # a word, so a header built from the RAW parameter would label a project-wide
    # list "March 2026". Only applied filters are reported.
    it 'drops a malformed date instead of labelling an unfiltered list with it' do
      book(minutes: 60, occurred_on: Date.new(2026, 3, 10))

      panel = call(project_id: project.id, start_date: '10.03.2026')

      expect(panel.filters).not_to have_key(:start_date)
      expect(panel.row_count).to eq(1)
    end

    # ⚠️ Regression. `Date.strptime` reads these as perfectly good years, and the
    # count in #call then reached PostgreSQL and threw PG::DatetimeFieldOverflow:
    # a 500 out of an address anybody can type. The form check has ONE owner now
    # (TimeSessions::DateBound); this pins the consequence at the panel, which is
    # where it was observable.
    ['999999999-01-01', '-9999-01-01', '99999-01-01'].each do |raw|
      it "survives #{raw.inspect}, a year PostgreSQL cannot store" do
        book(minutes: 60, occurred_on: Date.new(2026, 3, 10))

        panel = nil
        expect { panel = call(project_id: project.id, start_date: raw) }.not_to raise_error

        expect(panel).to be_available
        expect(panel.filters).not_to have_key(:start_date)
        expect(panel.row_count).to eq(1)
      end
    end

    it 'ignores a creator filter that is not a uuid' do
      book(minutes: 60)

      panel = call(project_id: project.id, creator_id: 'me')

      expect(panel.filters).not_to have_key(:creator_id)
      expect(panel.row_count).to eq(1)
    end
  end
end
