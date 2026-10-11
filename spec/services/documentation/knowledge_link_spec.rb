# frozen_string_literal: true

require 'rails_helper'

# What: Documentation::KnowledgeLink — the shared `lalabase://<type>/<uuid>` contract.
# Type: Unit spec (pure, no DB rows needed for parse/build shape).
# Why:  This string is the seam between the MCP tool that BUILDS links and the resolver
#       that PARSES them. A silent drift between build and parse would break every
#       author round-trip, so the format is pinned here in one place.
RSpec.describe Documentation::KnowledgeLink do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  describe '.parse' do
    it 'parses a note link into type + id' do
      id = SecureRandom.uuid
      expect(described_class.parse("lalabase://note/#{id}")).to eq(type: 'note', id: id)
    end

    it 'parses a document link into type + id' do
      id = SecureRandom.uuid
      expect(described_class.parse("lalabase://document/#{id}")).to eq(type: 'document', id: id)
    end

    it 'downcases the scheme + type so casing never changes the meaning' do
      id = SecureRandom.uuid
      expect(described_class.parse("LALABASE://NOTE/#{id}")).to eq(type: 'note', id: id)
    end

    it 'canonicalises an upper-case id to the stored lowercase form' do
      id = SecureRandom.uuid
      expect(described_class.parse("lalabase://note/#{id.upcase}")).to eq(type: 'note', id: id)
    end

    it 'returns nil for an unknown type (no silent new link kind)' do
      expect(described_class.parse("lalabase://ticket/#{SecureRandom.uuid}")).to be_nil
    end

    it 'returns nil for a non-UUID id (guards find_by against the uuid column)' do
      expect(described_class.parse('lalabase://note/not-a-uuid')).to be_nil
    end

    it 'returns nil for a foreign scheme or a plain relative link' do
      expect(described_class.parse("https://example.com/note/#{SecureRandom.uuid}")).to be_nil
      expect(described_class.parse('setup.md')).to be_nil
      expect(described_class.parse('#anchor')).to be_nil
      expect(described_class.parse(nil)).to be_nil
    end

    it 'anchors the pattern — no leading/trailing junk is accepted' do
      id = SecureRandom.uuid
      expect(described_class.parse("prefix lalabase://note/#{id}")).to be_nil
      expect(described_class.parse("lalabase://note/#{id}/extra")).to be_nil
    end
  end

  describe '.build' do
    it 'builds the canonical link for a note' do
      note = create(:note, project: project, organisation: organisation)
      expect(described_class.build(note)).to eq("lalabase://note/#{note.id}")
    end

    it 'builds the canonical link for a document' do
      document = create(:document, project: project, organisation: organisation)
      expect(described_class.build(document)).to eq("lalabase://document/#{document.id}")
    end

    it 'returns nil for an unsupported record class (no link the resolver cannot honour)' do
      ticket = create(:ticket, project: project, organisation: organisation)
      expect(described_class.build(ticket)).to be_nil
    end
  end

  describe 'build → parse round-trip' do
    it 'parses back to the same type + id for a note (the contract both halves rely on)' do
      note = create(:note, project: project, organisation: organisation)
      parsed = described_class.parse(described_class.build(note))
      expect(parsed).to eq(type: 'note', id: note.id)
    end

    it 'parses back to the same type + id for a document' do
      document = create(:document, project: project, organisation: organisation)
      parsed = described_class.parse(described_class.build(document))
      expect(parsed).to eq(type: 'document', id: document.id)
    end
  end

  describe '.key_for' do
    it 'maps both supported types by their polymorphic name' do
      note = create(:note, project: project, organisation: organisation)
      document = create(:document, project: project, organisation: organisation)
      expect(described_class.key_for(note)).to eq('note')
      expect(described_class.key_for(document)).to eq('document')
    end
  end
end
