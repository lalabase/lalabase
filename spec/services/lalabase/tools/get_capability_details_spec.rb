# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Tools::GetCapabilityDetails do
  let(:organisation) { create(:organisation) }
  let(:project)      { create(:project, organisation: organisation) }
  let(:chat)         { build(:chat, organisation: organisation).tap(&:save!) }
  let(:context)      { Lalabase::Tools::Context.new(chat: chat, organisation: organisation, project: project) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def vec(seed = 0.1)
    Array.new(1536, seed)
  end

  describe 'schema metadata' do
    it 'declares the public tool name' do
      expect(described_class.tool_name).to eq('get_capability_details')
    end

    it 'requires capability_id' do
      expect(described_class.input_schema[:required]).to eq(['capability_id'])
    end
  end

  describe '.execute' do
    it 'errors when capability_id is missing' do
      result = described_class.execute(args: {}, context: context)
      expect(result.error).to eq('capability_id is required')
    end

    it 'errors when capability_id is blank' do
      result = described_class.execute(args: { capability_id: '   ' }, context: context)
      expect(result.error).to eq('capability_id is required')
    end

    it 'errors when project context is missing' do
      blank = Lalabase::Tools::Context.new(chat: chat, organisation: organisation, project: nil)
      cap = create(:project_capability, project: project, organisation: organisation)
      result = described_class.execute(args: { capability_id: cap.id }, context: blank)
      expect(result.error).to eq('project context missing')
    end

    it 'returns a no-match success when capability does not exist (not an error)' do
      # "Not found" is an empty success — same convention as GetSymbolDetails
      # and ListCapabilities. Reserves Result#error for genuine failures.
      result = described_class.execute(args: { capability_id: SecureRandom.uuid }, context: context)
      expect(result.success?).to be true
      expect(result.content).to include('No capability found')
      expect(result.citations).to eq([])
      expect(result.kind).to eq(:empty)
    end

    it 'returns a no-match success when capability_id belongs to ANOTHER project (defense in depth)' do
      # The acts_as_tenant scope alone would allow this — the explicit
      # project_id where-clause is what blocks it.
      other_project = create(:project, organisation: organisation)
      foreign_cap = create(:project_capability, project: other_project, organisation: organisation)
      result = described_class.execute(args: { capability_id: foreign_cap.id }, context: context)
      expect(result.success?).to be true
      expect(result.content).to include('No capability found')
      expect(result.citations).to eq([])
      expect(result.kind).to eq(:empty)
    end

    it 'errors when capability_id is not a valid UUID format (avoids PG crash)' do
      # Without the UUID-format guard, find_by(id: "12345") would raise
      # ActiveRecord::StatementInvalid (PG::InvalidTextRepresentation) and
      # the Runner would record an opaque "tool crashed" entry instead of
      # a useful error message.
      result = described_class.execute(args: { capability_id: '12345' }, context: context)
      expect(result.success?).to be false
      expect(result.error).to eq('invalid capability_id format')
    end

    it 'reports missing project context BEFORE invalid format (most-actionable error first)' do
      blank = Lalabase::Tools::Context.new(chat: chat, organisation: organisation, project: nil)
      result = described_class.execute(args: { capability_id: '12345' }, context: blank)
      expect(result.error).to eq('project context missing')
    end

    it 'accepts 32-char no-dash UUID and resolves it to the same capability' do
      # R3-2: pin behavior, not absence-of-error. Postgres DOES coerce
      # the no-dash form back to the dashed UUID at the SQL layer
      # (verified live via rails runner). A mutation that widens the
      # regex to accept anything would still fail this because the
      # find_by would yield nil and we'd get a "No capability found"
      # success — not the populated citation we assert here.
      cap = create(:project_capability, project: project, organisation: organisation,
                                        name: 'NoDashTest', description: 'x')
      no_dash = cap.id.delete('-')
      expect(no_dash.length).to eq(32)
      result = described_class.execute(args: { capability_id: no_dash }, context: context)
      expect(result.success?).to be true
      expect(result.empty?).to be false
      expect(result.citations).to eq([{ type: 'capability', id: cap.id, name: 'NoDashTest' }])
    end

    # R3-4: validation-order has THREE boundaries; the existing "context BEFORE
    # format" test pins only the 2nd-vs-3rd one. This pins the 1st-vs-2nd:
    # blank capability_id must fire BEFORE missing project context.
    it 'reports missing capability_id BEFORE missing project context (first check wins)' do
      blank_ctx = Lalabase::Tools::Context.new(chat: chat, organisation: organisation, project: nil)
      result = described_class.execute(args: {}, context: blank_ctx)
      expect(result.error).to eq('capability_id is required')
    end

    # R4-2: explicit-blank-string variant. LLMs often emit `""` instead of
    # omitting the key entirely, so both paths must converge on the same
    # "capability_id is required" message.
    it 'reports missing capability_id when args has explicit empty string + nil project' do
      blank_ctx = Lalabase::Tools::Context.new(chat: chat, organisation: organisation, project: nil)
      result = described_class.execute(args: { capability_id: '' }, context: blank_ctx)
      expect(result.error).to eq('capability_id is required')
    end

    it 'rejects integer capability_id gracefully (LLM hallucination)' do
      result = described_class.execute(args: { capability_id: 99 }, context: context)
      expect(result.error).to eq('invalid capability_id format')
    end

    it 'tolerates nil args without raising (defensive against malformed tool_call)' do
      result = described_class.execute(args: nil, context: context)
      expect(result.error).to eq('capability_id is required')
    end

    it 'returns formatted content + citation for a valid capability' do
      cap = create(:project_capability, project: project, organisation: organisation,
                                        name: 'Authentication',
                                        description: 'Handles login and session lifecycle.',
                                        key_modules: ['app/models/user.rb', 'app/services/auth/login.rb'])
      result = described_class.execute(args: { capability_id: cap.id }, context: context)
      expect(result.success?).to be true
      expect(result.content).to include('## Authentication')
      expect(result.content).to include('Handles login and session lifecycle.')
      expect(result.content).to include('**Key modules:**')
      expect(result.content).to include('- app/models/user.rb')
      expect(result.citations).to eq([{ type: 'capability', id: cap.id, name: 'Authentication' }])
    end

    it 'omits the "Key modules" section when key_modules is empty' do
      cap = create(:project_capability, project: project, organisation: organisation,
                                        name: 'Bare', description: 'minimal', key_modules: [])
      result = described_class.execute(args: { capability_id: cap.id }, context: context)
      expect(result.content).not_to include('Key modules')
    end

    it 'caps description at MAX_DESCRIPTION_LEN' do
      cap = create(:project_capability, project: project, organisation: organisation,
                                        name: 'Big', description: 'd' * 5000)
      result = described_class.execute(args: { capability_id: cap.id }, context: context)
      expect(result.content).to include('d' * described_class::MAX_DESCRIPTION_LEN)
      expect(result.content).not_to include('d' * (described_class::MAX_DESCRIPTION_LEN + 1))
    end
  end
end
