# frozen_string_literal: true

require 'rails_helper'

# What: Mcp::ToolCall hands its token to the tool through Context#token, on the project
#   path and on the token path, and Base.readable_tickets cuts the rows by that token.
# Why: a Context without a token is the assistant's normal case and means "no second
#   limit" in Tickets::ReadableForToken. A branch of context_for that forgets the token
#   therefore raises nothing and widens the reach to the owner's rights. These examples
#   go through a real ToolCall, because that branch is the thing that can go wrong.
#
# Security spec: tagged :ci_guard and listed in .github/workflows/guards.yml.
RSpec.describe Mcp::ToolCall, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:owner) { create(:user) }
  let(:project_a) { in_tenant { create(:project, organisation: organisation) } }
  let(:project_b) { in_tenant { create(:project, organisation: organisation) } }
  let!(:ticket_a) { in_tenant { create(:ticket, project: project_a, organisation: organisation, creator: owner) } }
  let!(:ticket_b) { in_tenant { create(:ticket, project: project_b, organisation: organisation, creator: owner) } }
  let(:token) do
    create(:personal_access_token, user: owner, organisations: [organisation],
                                   project_scopes: { organisation => [project_a] })
  end

  before do
    in_tenant do
      create(:membership, user: owner, organisation: organisation,
                          role: create(:admin_role, organisation: organisation), active: true)
    end
    token
  end

  def in_tenant(&)
    ActsAsTenant.with_tenant(organisation, &)
  end

  def stub_tool(mode, &body)
    Class.new(Lalabase::Tools::Base) do
      define_singleton_method(:tool_name) { 'stub_tool' }
      define_singleton_method(:scope_mode) { mode }
      define_singleton_method(:execute) do |args:, context:| # rubocop:disable Lint/UnusedBlockArgument
        Lalabase::Tools::Result.new(content: instance_exec(context, &body))
      end
    end
  end

  def context_seen_by(mode, args)
    seen = nil
    tool = stub_tool(mode) do |context|
      seen = context
      'ok'
    end
    described_class.new(token: token, tool_class: tool, args: args).response
    seen
  end

  describe 'Context#token' do
    it 'carries the token on the project path' do
      context = context_seen_by(:project, { project_id: project_a.id })

      expect(context.project).to eq(project_a)
      expect(context.token).to eq(token)
    end

    it 'carries the token on the token path' do
      context = context_seen_by(:token, {})

      expect(context.reach).not_to be_nil
      expect(context.token).to eq(token)
    end
  end

  describe 'readable_tickets on the project path' do
    # The relation is wider than the gated project on purpose: the real tools narrow it
    # to context.project first, which would hide what this example is about.
    let(:lookup_tool) do
      stub_tool(:project) do |context|
        relation = Ticket.where(organisation_id: context.organisation.id)
        readable_tickets(context, relation).pluck(:id).join(',')
      end
    end

    it "cuts an account admin's rows to the reach of the token" do
      response = described_class.new(token: token, tool_class: lookup_tool, args: { project_id: project_a.id }).response

      expect(response).not_to be_error
      expect(response.content.first[:text]).to eq(ticket_a.id)
    end

    it 'leaves the same owner every ticket without a token, the assistant path' do
      context = Lalabase::Tools::Context.new(actor: owner, organisation: organisation)

      rows = in_tenant do
        Lalabase::Tools::Base.readable_tickets(context, Ticket.where(organisation_id: organisation.id)).pluck(:id)
      end

      expect(rows).to contain_exactly(ticket_a.id, ticket_b.id)
    end
  end

  describe 'the exclusive reach of Lalabase::Tools::Context' do
    let(:reach) { instance_double(PersonalAccessToken::Reach) }

    it 'still refuses a reach next to a project' do
      expect { Lalabase::Tools::Context.new(reach: reach, project: instance_double(Project)) }
        .to raise_error(ArgumentError)
    end

    it 'takes a reach next to a token' do
      expect { Lalabase::Tools::Context.new(reach: reach, token: instance_double(PersonalAccessToken)) }
        .not_to raise_error
    end
  end
end
