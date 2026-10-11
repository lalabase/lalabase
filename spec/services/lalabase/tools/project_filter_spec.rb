# frozen_string_literal: true

require 'rails_helper'

# S3a T5 (§9.3): the per-question project filter. The chip is a standing
# narrowing; this is the one that answers "how many tickets does Nordlicht
# have?" without changing any state.
#
# Before it existed that question had no correct answer on an org thread: the
# tool returns tickets of every reachable project, paginated, and its total
# counts them all. A model could only guess from one page.
RSpec.describe 'Tools project filter (T5)' do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
  end

  def project(name)
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: name) }
  end

  let!(:nordlicht) { project('Nordlicht Software') }
  let!(:portal) { project('Kundenportal v2') }

  let!(:nordlicht_tickets) do
    ActsAsTenant.with_tenant(organisation) { create_list(:ticket, 2, project: nordlicht, organisation: organisation) }
  end
  let!(:portal_ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: portal, organisation: organisation) }
  end

  let(:chat) do
    ActsAsTenant.with_tenant(organisation) { create(:chat, :org_thread, organisation: organisation, user: user) }
  end

  def context
    Lalabase::Tools::Context.new(
      chat: chat, organisation: organisation, project: nil, actor: user,
      scope: Lalabase::Tools::Scope.for(chat: chat, actor: user)
    )
  end

  def run(args)
    ActsAsTenant.with_tenant(organisation) do
      JSON.parse(Lalabase::Tools::ListTickets.execute(args: args, context: context).content)
    end
  end

  it 'answers the question the whole filter exists for' do
    result = run('project' => 'Nordlicht Software')

    expect(result['data'].size).to eq(2)
    expect(result['data'].map { |t| t.dig('project', 'name') }.uniq).to eq(['Nordlicht Software'])
  end

  it 'matches the name the way a user says it' do
    expect(run('project' => 'nordlicht')['data'].size).to eq(2)
  end

  it 'takes a UUID too' do
    expect(run('project' => nordlicht.id)['data'].size).to eq(2)
  end

  # An exact name must stay addressable even when it is contained in another.
  # Without the two-step match an organisation running "Portal" and "Portal v2"
  # could never mean the first one.
  it 'prefers an exact name over a longer one containing it' do
    exact = project('Portal')
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: exact, organisation: organisation) }

    result = run('project' => 'Portal')

    expect(result['data'].map { |t| t.dig('project', 'id') }.uniq).to eq([exact.id])
  end

  # §9.2 shape: a follow-up question the user answers with a click, never a
  # silent zero. A zero here would be indistinguishable from "that project has
  # no tickets", which is a different and much worse answer.
  it 'answers an ambiguous name with candidates instead of rows' do
    project('Nordlicht Hardware')

    result = run('project' => 'Nordlicht')

    expect(result['ambiguous_project']).to be(true)
    expect(result['candidates'].map { |c| c['name'] })
      .to match_array(['Nordlicht Software', 'Nordlicht Hardware'])
    expect(result).not_to have_key('data')
  end

  it 'says "unknown" rather than "ambiguous" for a name nobody has' do
    result = run('project' => 'Gibtsnicht')

    expect(result['unknown_project']).to be(true)
    expect(result['ambiguous_project']).to be(false)
    expect(result['candidates'].map { |c| c['name'] }).to include('Nordlicht Software')
  end

  # THE security property: the filter draws from the scope, so it can only ever
  # take projects away. A project the asker cannot read is not addressable by
  # name, and naming it must not turn into a way to read it.
  it 'cannot reach a project outside the asker\'s rights' do
    plain = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: plain, organisation: organisation,
                          role: create(:role, organisation: organisation, title: "Plain #{SecureRandom.hex(3)}"),
                          active: true)
    end
    plain_chat = ActsAsTenant.with_tenant(organisation) do
      create(:chat, :org_thread, organisation: organisation, user: plain)
    end
    plain_context = Lalabase::Tools::Context.new(
      chat: plain_chat, organisation: organisation, project: nil, actor: plain,
      scope: Lalabase::Tools::Scope.for(chat: plain_chat, actor: plain)
    )

    result = ActsAsTenant.with_tenant(organisation) do
      JSON.parse(Lalabase::Tools::ListTickets.execute(
        args: { 'project' => 'Nordlicht Software' }, context: plain_context
      ).content)
    end

    expect(result).not_to have_key('data')
    expect(result['candidates']).to be_empty
  end

  # The reported reach follows the filter. Without this the answer would carry
  # the org-wide count and claim to have looked at every project.
  #
  # It NAMES the project rather than counting it (T5 review): "Durchsucht: 1 von
  # 2 Projekten" is the sentence that reports a RIGHTS limit, and this narrowing
  # is the user's own -- they named the project in the question itself. `eq` and
  # not `include`, because a MISSING key is what went unnoticed here: `include`
  # passes just as happily on a hash that dropped the name.
  it 'reports a reach of one when it narrowed to one, and names it' do
    result = ActsAsTenant.with_tenant(organisation) do
      Lalabase::Tools::ListTickets.execute(args: { 'project' => 'Nordlicht Software' }, context: context)
    end

    expect(result.coverage).to eq(searched: 1, total: 2, chosen: 'Nordlicht Software')
  end

  # The counterweight, or the example above would also pass with a `chosen` that
  # is simply always set: no filter, no name, and the counted sentence is back.
  it 'carries no chosen project without the filter' do
    result = ActsAsTenant.with_tenant(organisation) do
      Lalabase::Tools::ListTickets.execute(args: {}, context: context)
    end

    expect(result.coverage).to eq(searched: 2, total: 2)
  end

  # The filter lives in Tools::Base and THREE tools reach for it. Testing it
  # through one of them proves the resolver, not the wiring -- and the wiring is
  # where each tool differs: GetTicket resolves BEFORE its lookup so a number can
  # be disambiguated, SummarizeTimeSessions before its sum.
  describe 'get_ticket' do
    def get_ticket(args)
      ActsAsTenant.with_tenant(organisation) do
        Lalabase::Tools::GetTicket.execute(args: args, context: context)
      end
    end

    # Ticket numbers are unique per PROJECT, so "#1" is genuinely ambiguous on an
    # org thread. Without the filter the only honest answer is a candidate list;
    # with it, "#1 in Nordlicht" is the sentence a user would actually say.
    it 'disambiguates a number that exists in two projects' do
      number = nordlicht_tickets.first.number
      # The premise, stated rather than assumed: numbers restart per project, so
      # this number really is ambiguous org-wide.
      expect(portal_ticket.number).to eq(number)
      expect(JSON.parse(get_ticket('number' => number.to_s).content)).to have_key('candidates')

      payload = JSON.parse(get_ticket('number' => number.to_s, 'project' => 'Nordlicht Software').content)

      expect(payload['id']).to eq(nordlicht_tickets.first.id)
      expect(payload).not_to have_key('candidates')
    end

    it 'wears the reach it actually had, not the org-wide one, and names it' do
      result = get_ticket('number' => nordlicht_tickets.first.number.to_s, 'project' => 'Nordlicht Software')

      expect(result.coverage).to eq(searched: 1, total: 2, chosen: 'Nordlicht Software')
    end

    it 'answers an unknown project name with candidates instead of a ticket' do
      payload = JSON.parse(get_ticket('number' => nordlicht_tickets.first.number.to_s,
                                      'project' => 'Gibtsnicht').content)

      expect(payload['unknown_project']).to be(true)
      expect(payload).not_to have_key('data')
    end
  end

  # The filter now has TWO ways to name its candidates (per-area gate, or a list
  # the tool hands in, because time sessions have no area). A tool that gives
  # neither must fail at the call, not three frames deeper on nil.to_sym.
  it 'refuses to resolve without a source of candidates' do
    expect do
      Lalabase::Tools::Base.resolve_project_filter({ project: 'Nordlicht Software' }, context)
    end.to raise_error(ArgumentError, /area: or candidates:/)
  end

  # R-M5: the single-project path (project chat, and the whole MCP surface, where
  # project_id is mandatory) stays untouched. Silently ignoring the argument
  # would let a model believe it narrowed something.
  it 'refuses the filter where the project is already fixed' do
    single = Lalabase::Tools::Context.new(
      chat: nil, organisation: organisation, project: nordlicht, actor: user, scope: nil
    )

    result = ActsAsTenant.with_tenant(organisation) do
      Lalabase::Tools::ListTickets.execute(args: { 'project' => 'Kundenportal v2' }, context: single)
    end

    expect(result.error).to be_present
  end
end
