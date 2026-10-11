# frozen_string_literal: true

require 'rails_helper'

# Failing-first (PE-2, Plan §3.2): the content area registry is the backbone of
# extensibility — fragmentable_type → area. It decides which type is gateable
# at all; an unregistered type is excluded fail-closed.
RSpec.describe Lalabase::ProjectRag::ContentAreaRegistry do
  describe '.area_for' do
    it 'maps Ticket to :tickets' do
      expect(described_class.area_for('Ticket')).to eq(:tickets)
    end

    it 'maps Post to :tickets (normalised like ProjectAccessService#normalize_area)' do
      expect(described_class.area_for('Post')).to eq(:tickets)
    end

    it 'maps Note to :notes' do
      expect(described_class.area_for('Note')).to eq(:notes)
    end

    it 'maps DocumentVersion to :documents' do
      expect(described_class.area_for('DocumentVersion')).to eq(:documents)
    end

    it 'maps DocumentationPage to :documentation (Slice 3)' do
      expect(described_class.area_for('DocumentationPage')).to eq(:documentation)
    end

    it 'maps Meeting to :meetings (Gespräche Slice 6)' do
      expect(described_class.area_for('Meeting')).to eq(:meetings)
    end

    it 'maps MeetingAnalysis to :meetings (Gespräche Slice 7b — same :meetings gate as its meeting)' do
      expect(described_class.area_for('MeetingAnalysis')).to eq(:meetings)
    end

    it 'maps TicketDocument to :tickets (an attachment is gated by the ticket it hangs on)' do
      expect(described_class.area_for('TicketDocument')).to eq(:tickets)
    end

    it 'maps PostDocument to :tickets (like its comment, which normalises to tickets)' do
      expect(described_class.area_for('PostDocument')).to eq(:tickets)
    end

    it 'returns nil for an unregistered type (fail-closed — no default leak)' do
      expect(described_class.area_for('User')).to be_nil
      expect(described_class.area_for('SomethingNew')).to be_nil
      expect(described_class.area_for(nil)).to be_nil
      expect(described_class.area_for('')).to be_nil
    end
  end

  describe '.registered_types' do
    it 'contains exactly the embeddable content types' do
      expect(described_class.registered_types)
        .to contain_exactly('Ticket', 'Post', 'Note', 'DocumentVersion', 'DocumentationPage', 'Meeting',
                            'MeetingAnalysis', 'TicketDocument', 'PostDocument')
    end
  end

  # Guard: every type that is REALLY embedded MUST be registered. The source of truth for
  # "really embedded" is EmbeddingReprocessingService (Note/Post/Ticket/DocumentVersion).
  # Prevents both: silently leaking a new type (embedded, but ungated) AND
  # silently swallowing one (embedded, but never surfaced). If a type is embedded without
  # a registry entry, this test breaks red.
  describe 'embeddable-type guard' do
    # DERIVED, not transcribed. Until 04.09.2026 this guard carried its own hardcoded
    # list of seven, and both lists were missing the same two types — so it stayed green
    # over exactly the gap it exists to catch (TicketDocument and PostDocument were
    # embedded and reachable from no retrieval seam for months). A guard that repeats the
    # thing it guards proves nothing; this one now reads the ingestion side.
    it 'registers EVERY type the ingestion side actually embeds' do
      # without_tenant because the relations are acts_as_tenant scopes and are built
      # eagerly when the hash is read — the same wrapper PendingEmbeddings' own spec uses.
      embedded = ActsAsTenant.without_tenant { Embeddings::PendingEmbeddings.relations_by_model.keys.map(&:name) }

      expect(embedded - described_class.registered_types).to be_empty
    end

    %w[Ticket Post Note DocumentVersion DocumentationPage Meeting MeetingAnalysis
       TicketDocument PostDocument].each do |type|
      it "registers the embeddable fragmentable type #{type}" do
        expect(described_class.registered_types).to include(type)
        expect(described_class.area_for(type)).to be_a(Symbol)
      end
    end
  end

  describe 'area symbols stay within the known permission canon' do
    it 'only emits areas that ProjectPolicy#area_access? understands' do
      # tickets/notes/documents/documentation are ProjectPermission columns;
      # time_sessions arrives later via the ProjectPolicy special path. No area
      # outside this canon.
      known = %i[tickets notes documents documentation time_sessions meetings]
      emitted = described_class.registered_types.map { |t| described_class.area_for(t) }.uniq
      expect(emitted - known).to be_empty
    end
  end

  # S3a T3: Fragment's per-type privacy predicates are the boundary BOTH context
  # scopes are built from (for_project_context / for_context_map). A registered
  # type without a predicate silently vanishes from retrieval in both paths, a
  # stray predicate would bind a type the registry never gates.
  describe 'context predicate guard (Fragment::TYPE_CONTEXT_PREDICATES)' do
    it 'carries exactly one predicate per registered type' do
      expect(Fragment::TYPE_CONTEXT_PREDICATES.keys).to match_array(described_class.registered_types)
    end
  end
end
