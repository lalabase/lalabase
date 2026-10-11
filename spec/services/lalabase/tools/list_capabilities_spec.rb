# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Tools::ListCapabilities do
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
      expect(described_class.tool_name).to eq('list_capabilities')
    end

    it 'takes no required argument, and offers the org-wide project filter' do
      # The filter is the ONLY property, and it is optional: this tool answers for
      # ONE project, and on an org thread that project has to be nameable. It is
      # the SHARED wording (Base::PROJECT_FILTER_SCHEMA), not a copy -- three
      # copies of a rights-narrowing description is how this feature drifted before.
      expect(described_class.input_schema[:type]).to eq('object')
      expect(described_class.input_schema[:required]).to eq([])
      expect(described_class.input_schema[:properties])
        .to eq(Lalabase::Tools::Base::PROJECT_FILTER_SCHEMA)
    end
  end

  describe '.execute' do
    it 'errors when project context is missing' do
      blank = Lalabase::Tools::Context.new(chat: chat, organisation: organisation, project: nil)
      result = described_class.execute(args: {}, context: blank)
      expect(result.error).to eq('project context missing')
    end

    it 'returns a friendly message and empty citations when no capabilities exist' do
      result = described_class.execute(args: {}, context: context)
      expect(result.success?).to be true
      expect(result.content).to include('No capabilities have been indexed')
      expect(result.citations).to eq([])
      expect(result.kind).to eq(:empty)
    end

    it 'lists capabilities by name, alphabetically sorted, with no citations' do
      create(:project_capability, project: project, organisation: organisation,
                                  name: 'ZetaThing')
      create(:project_capability, project: project, organisation: organisation,
                                  name: 'Authentication')
      result = described_class.execute(args: {}, context: context)
      expect(result.content).to eq("- Authentication\n- ZetaThing")
      expect(result.citations).to eq([])
    end

    it 'appends "... and more" footer when capability count exceeds MAX_LISTED' do
      (described_class::MAX_LISTED + 1).times do |i|
        create(:project_capability, project: project, organisation: organisation,
                                    name: "Cap#{format('%02d', i)}")
      end
      result = described_class.execute(args: {}, context: context)
      expect(result.content).to include('... and more')
      # Listed body must contain exactly MAX_LISTED bullets.
      expect(result.content.scan(/^- Cap\d{2}$/).size).to eq(described_class::MAX_LISTED)
    end

    it 'does NOT append "... and more" when count is exactly MAX_LISTED (boundary)' do
      # n boundary: catches off-by-one in the `caps.size > MAX_LISTED` predicate.
      described_class::MAX_LISTED.times do |i|
        create(:project_capability, project: project, organisation: organisation,
                                    name: "Cap#{format('%02d', i)}")
      end
      result = described_class.execute(args: {}, context: context)
      expect(result.content).not_to include('... and more')
    end

    it 'does not list capabilities from another project (project isolation)' do
      other_project = create(:project, organisation: organisation)
      create(:project_capability, project: other_project, organisation: organisation,
                                  name: 'OtherProjectCap')
      result = described_class.execute(args: {}, context: context)
      expect(result.content).not_to include('OtherProjectCap')
    end
  end
end
