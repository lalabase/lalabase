# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Tools::Base do
  describe 'abstract API contract' do
    it 'raises NotImplementedError for tool_name' do
      expect { described_class.tool_name }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for description' do
      expect { described_class.description }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for input_schema' do
      expect { described_class.input_schema }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for execute' do
      expect { described_class.execute(args: {}, context: nil) }.to raise_error(NotImplementedError)
    end
  end

  describe '.to_schema' do
    let(:dummy_tool) do
      Class.new(described_class) do
        def self.tool_name
          'dummy'
        end

        def self.description
          'A dummy tool used in specs'
        end

        def self.input_schema
          { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] }
        end
      end
    end

    it 'composes a provider-neutral schema hash from the overridden methods' do
      expect(dummy_tool.to_schema).to eq(
        name: 'dummy',
        description: 'A dummy tool used in specs',
        input_schema: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] }
      )
    end

    it 'propagates NotImplementedError if the subclass forgets to override a piece' do
      half_baked = Class.new(described_class) do
        def self.tool_name
          'half_baked'
        end

        def self.description
          'incomplete'
        end
        # input_schema deliberately not overridden
      end
      expect { half_baked.to_schema }.to raise_error(NotImplementedError)
    end
  end

  # R4-3 (strict-review audit): Base#repo_ids_for is the shared helper used by
  # SearchCodeSymbols + GetSymbolDetails. Both current callers guard against
  # nil project before calling, but the method is public — a future tool that
  # forgets the guard would otherwise crash with NoMethodError on
  # `context.project.id`. The defensive `return [] if project.nil?` keeps
  # the contract safe.
  describe '.repo_ids_for' do
    let(:organisation) { create(:organisation) }

    before { ActsAsTenant.current_tenant = organisation }
    after  { ActsAsTenant.current_tenant = nil }

    it 'returns [] when context.project is nil (no NoMethodError crash)' do
      ctx = Lalabase::Tools::Context.new(chat: nil, organisation: organisation, project: nil)
      expect(described_class.repo_ids_for(ctx)).to eq([])
    end

    it 'returns [pinned] when chat.project_repository_id is set (regardless of project state)' do
      project = create(:project, organisation: organisation)
      repo = create(:project_repository, project: project, organisation: organisation)
      # ⚠️ Written as a raw column, and that is the state of this feature since
      # projekt_chat_abbau: `project_repository_id` has no association and no
      # validation behind it any more (the cross-project guard could never pass once
      # no chat carried a project), and it has had no write path in the app for longer
      # than that. repo_ids_for still READS it, so the pin keeps its meaning for the
      # day one comes back.
      chat = create(:chat, organisation: organisation)
      chat.update_column(:project_repository_id, repo.id)
      ctx = Lalabase::Tools::Context.new(chat: chat, organisation: organisation, project: project)
      expect(described_class.repo_ids_for(ctx)).to eq([repo.id])
    end

    it 'returns all project repos when chat is not pinned' do
      project = create(:project, organisation: organisation)
      repo_a = create(:project_repository, project: project, organisation: organisation)
      repo_b = create(:project_repository, project: project, organisation: organisation)
      chat = build(:chat, organisation: organisation).tap(&:save!)
      ctx = Lalabase::Tools::Context.new(chat: chat, organisation: organisation, project: project)
      expect(described_class.repo_ids_for(ctx)).to contain_exactly(repo_a.id, repo_b.id)
    end

    # The assistant code tools pass a project they resolved themselves, because on
    # an org thread context.project is nil by contract.
    it 'takes the project the caller resolved over the (absent) context one' do
      project = create(:project, organisation: organisation)
      repo = create(:project_repository, project: project, organisation: organisation)
      thread = create(:chat, :org_thread, organisation: organisation, user: create(:user))
      ctx = Lalabase::Tools::Context.new(chat: thread, organisation: organisation, project: nil)

      expect(described_class.repo_ids_for(ctx, project: project)).to eq([repo.id])
    end

    # Was: "cannot be handed a pinned org thread, because Chat refuses to be one".
    # The validation that refused it went with projekt_chat_abbau -- it compared the
    # repository's project against the chat's, and no chat has one. What replaces it
    # is the absence of a WRITE PATH: nothing in the app sets the column, so a pin can
    # only appear by a raw update, and repo_ids_for reads it exactly as before.
    it 'has no association to pin through any more' do
      expect(Chat.reflect_on_association(:project_repository)).to be_nil
      expect(Chat.column_names).to include('project_repository_id')
    end
  end
end
