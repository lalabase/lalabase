# frozen_string_literal: true

require 'rails_helper'

# What: a project-mode MCP tool runs only when the token reaches the project AND its
#   owner may use the project right now (checked once, at the seam); a code tool
#   additionally needs the code read right (ProjectRepositoryPolicy#show?).
# Why: the seam asked the token alone. A token with all_projects opened every project
#   of the organisation, and a token linked to a project kept it open after the owner
#   lost access. Each tool had to remember its own check; the five code tools did not
#   until #909. The seam check makes the next tool that forgets it safe as well, like
#   the read-only gate at the same seam.
RSpec.describe 'MCP project reach follows the owner', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:membership) { create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation)) }
  let(:granted) { create(:project, organisation: organisation) }
  let(:other) { create(:project, organisation: organisation) }
  let(:permission) do
    create(:project_permission, user: user, project: granted, tickets_access: :read_write, chats_access: :read_only)
  end

  code_tools = %w[search_code_symbols get_symbol_details list_capabilities get_capability_details get_project_vision]

  before do
    ActsAsTenant.current_tenant = organisation
    # search_code_symbols embeds its query first; without a provider it fails before
    # rights play any part, which would make its refusal below pass for the wrong reason
    allow(Lalabase::QueryEmbedding).to receive(:embed).and_return([0.1, 0.2, 0.3])
    allow(CodeSymbol).to receive(:semantic_search).and_return(CodeSymbol.none)
    Prosopite.pause do
      membership
      permission
      [granted, other].each do |project|
        create(:project_capability, project: project, organisation: organisation, name: "Billing #{project.id}")
        repository = create(:project_repository, project: project, organisation: organisation)
        create(:code_symbol, project_repository: repository, name: 'billing', qualified_name: "Billing#{project.id.delete('-')}#call")
      end
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  def token(project_scopes: {})
    build(:personal_access_token, user: user, organisations: [organisation], project_scopes: project_scopes).tap do |pat|
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
    end
  end

  let(:all_projects_token) { token }

  # Real arguments for the project's own data, so a refusal cannot be a plain "not found"
  def arguments(project)
    ActsAsTenant.with_tenant(organisation) do
      { project_id: project.id, query: 'billing',
        capability_id: ProjectCapability.find_by!(project: project).id,
        qualified_name: CodeSymbol.joins(:project_repository)
                                  .find_by!(project_repositories: { project_id: project.id }).qualified_name }
    end
  end

  def call_tool(pat, name, project)
    post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/call',
                               params: { name: name, arguments: arguments(project) } }.to_json,
                     headers: { 'Authorization' => "Bearer #{pat.token}", 'CONTENT_TYPE' => 'application/json' }
    response.parsed_body['result']
  end

  def refused?(result)
    result['isError'] == true
  end

  # The same calls succeed where the owner has the rights, so every refusal below is
  # about rights and not about arguments
  (code_tools + %w[list_tickets]).each do |tool|
    it "runs #{tool} on a project the owner may read" do
      expect(call_tool(all_projects_token, tool, granted)['isError']).to be_falsey
    end

    it "refuses #{tool} on a project of the organisation the owner has no right in" do
      expect(refused?(call_tool(all_projects_token, tool, other))).to be(true)
    end
  end

  context 'with a tool that forgets to check any right' do
    let(:careless_tool) do
      Class.new(Lalabase::Tools::Base) do
        def self.tool_name = 'careless_project_tool'
        def self.description = 'Test-only project tool that checks no right of its own.'
        def self.input_schema = { type: 'object', properties: {}, required: [] }
        def self.execute(context:, **) = Lalabase::Tools::Result.new(content: "served #{context.project.name}")
      end
    end

    before { stub_const('Mcp::Dispatcher::TOOLS', Mcp::Dispatcher::TOOLS + [careless_tool]) }

    it 'still keeps a project the owner has no right in closed' do
      result = call_tool(all_projects_token, 'careless_project_tool', other)

      expect(refused?(result)).to be(true)
      expect(result.dig('content', 0, 'text')).not_to include(other.name)
    end

    it 'runs it where the owner has access' do
      expect(call_tool(all_projects_token, 'careless_project_tool', granted).dig('content', 0, 'text'))
        .to include(granted.name)
    end
  end

  it 'refuses a project the token names once the owner has lost access to it' do
    pat = token(project_scopes: { organisation => [granted] })
    permission.destroy!

    expect(refused?(call_tool(pat, 'list_tickets', granted))).to be(true)
  end

  it 'refuses every project once the owner is deactivated' do
    membership.update!(active: false)

    expect(refused?(call_tool(all_projects_token, 'list_tickets', granted))).to be(true)
  end

  it 'refuses a code tool to an owner with ticket access but no code right' do
    permission.update!(chats_access: :no_access)

    expect(refused?(call_tool(all_projects_token, 'list_capabilities', granted))).to be(true)
    expect(call_tool(all_projects_token, 'list_tickets', granted)['isError']).to be_falsey
  end
end
