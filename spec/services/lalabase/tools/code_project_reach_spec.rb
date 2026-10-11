# frozen_string_literal: true

require 'rails_helper'

# What: which project the five code tools answer for on an org-wide assistant
#       thread, and whose code they may reach at all
#       (doc/assistent_code_werkzeuge_plan.md §A and "The rights rule").
# Type: Service spec.
# Why:  Two rules meet here, and both have exactly one owner on purpose.
#
#       The REACH is `chats:read OR documentation:write` -- ProjectPermission has
#       no `repositories` area, so ProjectRepositoryPolicy::Scope is the only
#       place that answers "whose repositories may this person see". A tool that
#       re-derived it as `area: :chats` would silently drop the documentation
#       half, which is the shape of defect this feature has produced before; the
#       documentation-branch example below is the one that fails if anybody does.
#
#       The LADDER is how one project is picked out of that reach. Vision and
#       capabilities are 1:1 per project, so three of the five tools have no
#       "all projects" answer to give -- naming the wrong one is worse than
#       asking, and asking is what rung 5 does.
RSpec.describe 'Assistant code tools: which project they answer for' do
  let(:organisation) { create(:organisation) }
  let(:role)         { create(:role, organisation: organisation, is_default: true) }
  let(:actor)        { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: actor, organisation: organisation, role: role, active: true)
  end

  after { ActsAsTenant.current_tenant = nil }

  def make_project(name)
    create(:project, organisation: organisation, name: name)
  end

  def connect_repo(project)
    create(:project_repository, project: project, organisation: organisation)
  end

  # The two halves of the repository read rule, one helper each, so an example
  # says which half it stands on.
  def allow_chats(project)
    create(:project_permission, user: actor, project: project, chats_access: 'read_only')
  end

  def allow_documentation(project)
    create(:project_permission, user: actor, project: project, documentation_access: 'read_write')
  end

  let(:chat) { create(:chat, :org_thread, organisation: organisation, user: actor) }

  def org_context
    Lalabase::Tools::Context.new(chat: chat.reload, organisation: organisation, project: nil, actor: actor,
                                 scope: Lalabase::Tools::Scope.for(chat: chat.reload, actor: actor))
  end

  # The cheapest of the five (no repository index, no embedding) and therefore the
  # one the ladder is driven with. The "every code tool" section below proves the
  # other four take the same ladder rather than a copy of it.
  def vision_for(args = {})
    Lalabase::Tools::GetProjectVision.execute(args: args, context: org_context)
  end

  def payload(result)
    JSON.parse(result.content)
  end

  describe 'the ladder (§A)' do
    let!(:alpha) { make_project('Alpha Portal') }
    let!(:beta)  { make_project('Beta Werkstatt') }

    before do
      connect_repo(alpha)
      connect_repo(beta)
      allow_chats(alpha)
      allow_chats(beta)
      create(:project_layer4_vision, project: alpha, organisation: organisation, content: 'Alpha does invoices.')
      create(:project_layer4_vision, project: beta, organisation: organisation, content: 'Beta does logistics.')
    end

    # Rung 1 lives in the "every code tool" section: it is the single-project path,
    # and the point of it is that ALL five are unchanged there (R-M5).

    it 'rung 2: answers for the project the question names' do
      result = vision_for(project: 'Alpha Portal')

      expect(result.content).to include('Alpha does invoices.')
      expect(result.content).not_to include('Beta does logistics.')
    end

    it 'rung 2: an ambiguous name answers with candidates, not with a guess' do
      archiv = make_project('Alpha Portal Archiv')
      connect_repo(archiv)
      allow_chats(archiv)

      result = vision_for(project: 'Alpha')

      expect(payload(result)['ambiguous_project']).to be true
      expect(payload(result)['candidates'].map { |c| c['name'] }).to include('Alpha Portal', 'Alpha Portal Archiv')
    end

    it 'rung 2: an unknown name says so instead of falling back to a project' do
      result = vision_for(project: 'Gibt es nicht')

      expect(payload(result)['unknown_project']).to be true
      expect(result.content).not_to include('Alpha does invoices.')
    end

    it 'rung 3: without an argument the scope chip decides' do
      chat.update!(scope_project_id: beta.id)

      expect(vision_for.content).to include('Beta does logistics.')
    end

    it 'rung 4: with nothing named and one reachable project, that one' do
      # Beta loses its repository, so exactly one project has code in reach.
      beta.project_repositories.destroy_all

      expect(vision_for.content).to include('Alpha does invoices.')
    end

    it 'rung 5: with nothing named and several reachable, it ASKS' do
      result = vision_for

      expect(payload(result)['project_required']).to be true
      expect(payload(result)['candidates'].map { |c| c['name'] }).to contain_exactly('Alpha Portal', 'Beta Werkstatt')
      expect(result.content).not_to include('Alpha does invoices.')
      expect(result.content).not_to include('Beta does logistics.')
    end

    it 'rung 5 reports the reach it could not choose from (L7)' do
      expect(vision_for.coverage).to eq(searched: 2, total: 2)
    end

    it 'answers with an empty success when no project in reach has a repository' do
      alpha.project_repositories.destroy_all
      beta.project_repositories.destroy_all

      result = vision_for

      expect(result.success?).to be true
      expect(result.kind).to eq(:empty)
      expect(result.content).to include('No project with a connected code repository is reachable')
      expect(result.coverage).to eq(searched: 0, total: 2)
    end

    # The answer names the project because nothing else in it does: a vision text,
    # a capability list and a file path all fail to say whose they are, and
    # `coverage` never reaches the model.
    it 'says which project it answered for, in the content' do
      expect(vision_for(project: 'Alpha Portal').content).to start_with('Project: Alpha Portal')
    end

    describe 'coverage (L7): named when the question named it, counted otherwise' do
      it 'names the project the question named' do
        expect(vision_for(project: 'Alpha Portal').coverage).to eq(searched: 1, total: 2, chosen: 'Alpha Portal')
      end

      it 'names the chip when the chip decided' do
        chat.update!(scope_project_id: beta.id)

        expect(vision_for.coverage).to eq(searched: 1, total: 2, chosen: 'Beta Werkstatt')
      end

      # Nobody asked for this narrowing, the rights and the data imposed it, so it
      # wears the fraction that says so rather than a name that sounds chosen.
      it 'counts when neither the question nor the chip chose' do
        beta.project_repositories.destroy_all

        expect(vision_for.coverage).to eq(searched: 1, total: 2)
      end
    end
  end

  describe 'the rights rule: whose code is in reach' do
    let!(:mine)    { make_project('Mein Projekt') }
    let!(:foreign) { make_project('Fremdes Projekt') }

    before do
      connect_repo(mine)
      connect_repo(foreign)
      allow_chats(mine)
      create(:project_layer4_vision, project: foreign, organisation: organisation, content: 'Fremde Vision.')
    end

    it 'leaves a project out of the candidates when the asker may not see its repositories' do
      mine.project_repositories.destroy_all

      result = vision_for

      expect(result.kind).to eq(:empty)
      expect(result.content).to include('No project with a connected code repository is reachable')
    end

    it 'naming it explicitly does not make it a candidate' do
      result = vision_for(project: 'Fremdes Projekt')

      expect(payload(result)['unknown_project']).to be true
      expect(result.content).not_to include('Fremde Vision.')
    end

    # THE example this file exists for. ProjectRepositoryPolicy::Scope reads
    # `chats:read OR documentation:write`; a hand-written `area: :chats` passes
    # every other example here and fails this one.
    it 'reaches the code of a project the asker may only write documentation in' do
      allow_documentation(foreign)

      expect(vision_for(project: 'Fremdes Projekt').content).to include('Fremde Vision.')
    end

    it 'gives an account admin every project with a repository' do
      actor.memberships.find_by(organisation: organisation)
           .update!(role: create(:role, organisation: organisation, title: 'account_admin'))

      expect(payload(vision_for)['candidates'].map { |c| c['name'] })
        .to contain_exactly('Mein Projekt', 'Fremdes Projekt')
    end

    # The chip INTERSECTS, it never replaces -- the same rule Scope#resolve_project_ids
    # follows for the area reach. Without it a chip would be a way into code its
    # owner may not read, which is the whole reason rungs 3 and 4 are one rung.
    it 'a chip on a project whose code is out of reach leaves nothing, it does not open it' do
      # The chip can only name a project the asker SEES (Scope#selection re-resolves
      # it through AssistantScopeOptions), so the case is a project visible through
      # some other area while its repositories are not: tickets, here.
      create(:project_permission, user: actor, project: foreign, tickets_access: 'read_only')
      # `mine` is reachable and has a vision, so "answered for the wrong project"
      # is distinguishable from "answered for none". Without that the example is
      # green whether the chip intersects or is ignored altogether.
      create(:project_layer4_vision, project: mine, organisation: organisation, content: 'Meine Vision.')
      chat.update!(scope_project_id: foreign.id)
      expect(Lalabase::Tools::Scope.for(chat: chat.reload, actor: actor).selection).to eq(foreign)

      result = vision_for

      expect(result.kind).to eq(:empty)
      expect(result.content).to include('No project with a connected code repository is reachable')
      expect(result.content).not_to include('Fremde Vision.')
      expect(result.content).not_to include('Meine Vision.')
    end

    it 'leaves an archived project out, repository or not' do
      # Both projects reachable, so only the archiving can decide the outcome:
      # unarchived this would be rung 5 (two candidates, it asks).
      allow_chats(foreign)
      create(:project_layer4_vision, project: mine, organisation: organisation, content: 'Meine Vision.')
      foreign.update!(archived_at: Time.current)

      result = vision_for

      expect(result.content).to include('Meine Vision.')
      expect(result.coverage).to eq(searched: 1, total: 1)
    end

    it 'gives an inactive member nothing (fail-closed)' do
      actor.memberships.find_by(organisation: organisation).update!(active: false)

      expect(vision_for.kind).to eq(:empty)
    end
  end

  # Five tools, ONE ladder. Each example below would also pass against five copies
  # of it; what they pin is that every tool HAS the org path at all, and that none
  # of them changed on the single-project path.
  describe 'every code tool' do
    let!(:alpha) { make_project('Alpha Portal') }
    let!(:beta)  { make_project('Beta Werkstatt') }
    let!(:alpha_repo) { connect_repo(alpha) }

    before do
      connect_repo(beta)
      allow_chats(alpha)
      allow_chats(beta)
      allow(Lalabase::QueryEmbedding).to receive(:embed).and_return(Array.new(1536, 0.1))
      allow(CodeSymbol).to receive(:semantic_search).and_return([])
    end

    let(:capability) { create(:project_capability, project: alpha, organisation: organisation, name: 'Rechnungen') }

    # Minimal valid arguments per tool, plus the project the question names.
    def call(tool, extra = {})
      tool.execute(args: { project: 'Alpha Portal' }.merge(extra), context: org_context)
    end

    it 'search_code_symbols searches the named project, and only its repositories' do
      result = call(Lalabase::Tools::SearchCodeSymbols, query: 'invoice')

      expect(result.content).to start_with('Project: Alpha Portal')
      expect(CodeSymbol).to have_received(:semantic_search).with(hash_including(repo_ids: [alpha_repo.id]))
    end

    it 'get_symbol_details looks in the named project, not in the other one' do
      create(:code_symbol, project_repository: alpha_repo, organisation: organisation,
                           qualified_name: 'Invoice#total', file_path: 'app/models/invoice.rb')
      create(:code_symbol, project_repository: beta.project_repositories.first, organisation: organisation,
                           qualified_name: 'Invoice#total', file_path: 'lib/beta/invoice.rb')

      result = call(Lalabase::Tools::GetSymbolDetails, qualified_name: 'Invoice#total')

      expect(result.content).to include('app/models/invoice.rb')
      expect(result.content).not_to include('lib/beta/invoice.rb')
    end

    it 'get_project_vision answers for the named project' do
      create(:project_layer4_vision, project: alpha, organisation: organisation, content: 'Alpha does invoices.')

      expect(call(Lalabase::Tools::GetProjectVision).content).to include('Alpha does invoices.')
    end

    it 'list_capabilities lists the named project' do
      capability
      create(:project_capability, project: beta, organisation: organisation, name: 'Logistik')

      result = call(Lalabase::Tools::ListCapabilities)

      expect(result.content).to include('Rechnungen')
      expect(result.content).not_to include('Logistik')
    end

    it 'get_capability_details resolves inside the named project' do
      result = call(Lalabase::Tools::GetCapabilityDetails, capability_id: capability.id)

      expect(result.content).to include('Rechnungen')
    end

    # A capability of a project the question did NOT name stays out of reach even
    # with a valid UUID: the project filter decides the where-clause, so the id
    # simply does not resolve.
    it 'get_capability_details does not reach a capability of another project by id' do
      foreign_capability = create(:project_capability, project: beta, organisation: organisation, name: 'Logistik')

      result = call(Lalabase::Tools::GetCapabilityDetails, capability_id: foreign_capability.id)

      expect(result.kind).to eq(:empty)
      expect(result.content).not_to include('Logistik')
    end

    describe 'the single-project path stays untouched (R-M5)' do
      let(:project_chat) { create(:chat, organisation: organisation) }
      let(:single_context) do
        Lalabase::Tools::Context.new(chat: project_chat, organisation: organisation, project: alpha, actor: actor)
      end

      def single(tool, args = {})
        tool.execute(args: args, context: single_context)
      end

      it 'answers without naming the project, byte-identical to before' do
        create(:project_layer4_vision, project: alpha, organisation: organisation, content: 'Alpha does invoices.')

        expect(single(Lalabase::Tools::GetProjectVision).content).to eq('Alpha does invoices.')
      end

      it 'reports no coverage, because there is no org-wide reach to report' do
        expect(single(Lalabase::Tools::ListCapabilities).coverage).to be_nil
      end

      it 'refuses a project filter rather than ignoring it, in every one of the five' do
        [[Lalabase::Tools::SearchCodeSymbols, { query: 'x' }],
         [Lalabase::Tools::GetSymbolDetails, { qualified_name: 'Foo' }],
         [Lalabase::Tools::GetProjectVision, {}],
         [Lalabase::Tools::ListCapabilities, {}],
         [Lalabase::Tools::GetCapabilityDetails, { capability_id: SecureRandom.uuid }]].each do |tool, args|
          result = single(tool, args.merge(project: 'Beta Werkstatt'))

          expect(result.error).to eq('the project filter applies to org-wide calls only'), tool.tool_name
        end
      end

      it 'still says "project context missing" when there is neither a project nor a scope' do
        blank = Lalabase::Tools::Context.new(chat: project_chat, organisation: organisation, project: nil,
                                             actor: actor)

        expect(single_missing(blank)).to eq('project context missing')
      end

      def single_missing(blank)
        Lalabase::Tools::GetProjectVision.execute(args: {}, context: blank).error
      end
    end
  end
end
