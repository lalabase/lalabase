# frozen_string_literal: true

require 'rails_helper'

# What: The drill-down promise of the chat time report (Zweitreview F1). The help
#       text says the citation link opens the time list "with exactly the filters
#       the number was computed from". The index has its own defaults (current
#       month, billed hidden), so the link must neutralise them via
#       TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS.
# Type: Request spec (mechanism, not declaration): the list under the neutralised
#       params must sum to the SAME minutes the tool reported. The component spec
#       pins that the chip href carries these params; together they close the loop.
RSpec.describe 'Time report citation drill-down', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:user)         { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  # Bare keywords in run_tool(...) are the tool ARGS; the parity example below
  # asks as a different actor via run_tool_as.
  def run_tool(args = {})
    run_tool_as(user, args)
  end

  def run_tool_as(actor, args = {})
    context = Lalabase::Tools::Context.new(actor: actor, organisation: organisation, project: project)
    JSON.parse(Lalabase::Tools::SummarizeTimeSessions.execute(args: args, context: context).content)
  end

  def list_sum(params)
    get organisation_time_sessions_path(organisation, project_id_filter: project.id, **params)
    expect(response).to have_http_status(:ok)
    assigns(:total_filtered_duration)
  end

  context 'with sessions the index defaults would hide (billed, older than this month)' do
    before do
      billed_group = create(:time_session_group, :billed, organisation: organisation)
      create(:time_session, project: project, organisation: organisation, creator: user, duration: 10,
                            billed: true, time_session_group: billed_group,
                            occurred_on: Time.zone.parse('2025-11-03 10:00'))
      create(:time_session, project: project, organisation: organisation, creator: user, duration: 20,
                            occurred_on: Time.zone.parse('2026-02-10 10:00'))
      create(:time_session, project: project, organisation: organisation, creator: user, duration: 40,
                            occurred_on: Time.current)
    end

    it 'the neutralised link shows exactly the minutes the tool reported' do
      report = run_tool
      expect(report['total']['minutes']).to eq(70)

      expect(list_sum(TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS)).to eq(70)
    end

    # The counter-half that makes the equality above meaningful: WITHOUT the
    # neutralising params the index falls back to current month + billed hidden
    # and shows a different number. If this ever passes with 70, the defaults
    # changed and the neutralisation (plus this file) can be reconsidered.
    it 'the bare index defaults show a different number (the bug the link had)' do
      report = run_tool
      expect(report['total']['minutes']).to eq(70)

      expect(list_sum({})).to eq(40)
    end

    # Review-Follow-up: the SEARCH filter adds .distinct on the outer relation
    # (the plain sort path tucks its distinct into a FROM subquery, which is why
    # this needs search to reproduce), and Rails folds that into
    # SUM(DISTINCT duration) — two equal 60-minute rows summed to 60. Equal
    # durations on purpose: distinct values cannot catch this.
    it 'equal durations are not collapsed under search: the list sum matches the tool total' do
      create(:time_session, project: project, organisation: organisation, creator: user, duration: 60,
                            description: 'Doppelrunde eins', occurred_on: Time.zone.parse('2026-05-05 09:00'))
      create(:time_session, project: project, organisation: organisation, creator: user, duration: 60,
                            description: 'Doppelrunde zwei', occurred_on: Time.zone.parse('2026-05-06 09:00'))

      report = run_tool(start_date: '2026-05-05', end_date: '2026-05-06')
      expect(report['total']['minutes']).to eq(120)

      params = TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS
               .merge(start_date: '2026-05-05', end_date: '2026-05-06', search: 'Doppelrunde')
      expect(list_sum(params)).to eq(120)
    end

    it 'a period filter carries over: custom dates win over date_range=all' do
      report = run_tool(start_date: '2026-01-01', end_date: '2026-03-01')
      expect(report['total']['minutes']).to eq(20)

      params = TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS.merge(start_date: '2026-01-01', end_date: '2026-03-01')
      expect(list_sum(params)).to eq(20)
    end
  end

  # Drittreview: parity for the OWN tier. The tool narrows a can_view_own user
  # to their own minutes (ViewingScope); the list behind the citation link must
  # show the SAME sum, or the chip disproves the answer it stands for. Today the
  # index does not apply TimeSessionPolicy::Scope (known gap, separate fix
  # branch), so this example fails on the sum and is marked pending; once the
  # fix branch is merged it goes green and forces the pending marker out.
  context 'with a can_view_own-only user and a foreign session' do
    let(:default_role) { create(:role, organisation: organisation, is_default: true) }
    let(:own_viewer)   { create(:user) }
    let(:colleague)    { create(:user) }

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: own_viewer, organisation: organisation, role: default_role, active: true)
        create(:membership, user: colleague, organisation: organisation, role: default_role, active: true)
      end
      create(:time_session_permission, user: own_viewer, project: project, can_view_own: true, can_view_all: false)
      create(:time_session, project: project, organisation: organisation, creator: own_viewer, duration: 25,
                            occurred_on: Time.current)
      create(:time_session, project: project, organisation: organisation, creator: colleague, duration: 35,
                            occurred_on: Time.current)
      sign_in own_viewer
    end

    # Viertreview F2/F3: the preconditions live OUTSIDE the pending marker. A
    # pending example is tolerant of ANY failure inside it, so with the tool
    # assertions inside it a broken ViewingScope or a wrong actor in the helper
    # would be swallowed as "expected". This example is the real guard for both.
    it 'the tool reports only the OWN minutes for a can_view_own user (precondition of the parity promise)' do
      report = run_tool_as(own_viewer)

      expect(report['scope']).to eq('own')
      expect(report['total']['minutes']).to eq(25)
    end

    # Live since the merge of fix/zeitenliste-sichtstufen (the pending marker
    # this example carried until then fired as designed and was removed): the
    # index narrows through TimeSessionPolicy::Scope, so the chip's sum now
    # matches the tool's own-tier number.
    it 'the neutralised link shows exactly the OWN minutes the tool reported' do
      expect(list_sum(TimeSession::LIST_NEUTRAL_DRILLDOWN_PARAMS)).to eq(25)
    end
  end
end
