# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Tools::GetProjectVision do
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
      expect(described_class.tool_name).to eq('get_project_vision')
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

    it 'returns a friendly message and empty citations when no vision is indexed' do
      result = described_class.execute(args: {}, context: context)
      expect(result.success?).to be true
      expect(result.content).to include('No vision has been indexed')
      expect(result.citations).to eq([])
      expect(result.kind).to eq(:empty)
    end

    it 'returns the vision content (capped) and a single vision citation when one exists' do
      vision = create(:project_layer4_vision, project: project, organisation: organisation,
                                              content: 'The system manages projects.')
      result = described_class.execute(args: {}, context: context)
      expect(result.success?).to be true
      expect(result.content).to eq('The system manages projects.')
      expect(result.citations).to eq([{ type: 'vision', id: vision.id }])
    end

    it 'caps content at MAX_CONTENT_LEN characters' do
      long = 'x' * (described_class::MAX_CONTENT_LEN + 100)
      create(:project_layer4_vision, project: project, organisation: organisation,
                                     content: long)
      result = described_class.execute(args: {}, context: context)
      expect(result.content.length).to eq(described_class::MAX_CONTENT_LEN)
    end

    it 'does not return a vision belonging to a different project (tenant/project isolation)' do
      other_project = create(:project, organisation: organisation)
      create(:project_layer4_vision, project: other_project, organisation: organisation,
                                     content: 'Other')
      result = described_class.execute(args: {}, context: context)
      expect(result.citations).to eq([])
      expect(result.content).to include('No vision has been indexed')
    end
  end
end
