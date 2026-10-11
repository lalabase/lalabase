# frozen_string_literal: true

# What: Guard — every reader of "which content is embedded, and what is outstanding"
#   DERIVES from Embeddings::ContentTypes, and the readers agree on real records.
# Type: Derivation guard (stubbed registry) + behavioural parity over EVERY registered type.
# Why (philosophy): Until 04.09.2026 this file compared two hand-kept lists by table name
#   and probed one type's behaviour. Both halves were blind to the third reader, the sync
#   page, which had drifted to four types and to a fragment type that does not exist. A
#   guard that compares transcripts proves the transcripts match; it proves nothing about
#   a reader that keeps its own. So the first half now REMOVES a type from the registry
#   and requires every reader to lose it — a private list keeps counting and turns red.
#   The second half builds one pending record of EVERY registered type and requires the
#   three readers to arrive at the same number, with the builder table pinned to the
#   registry's keys so a tenth type cannot go unprobed.
# Contract: PendingEmbeddings, IndexHealth and AiSyncStatusService read
#   Embeddings::ContentTypes; their pending counts agree per type; a failed record is the
#   one deliberate difference (the button retries it, the counts report it as failed).

require 'rails_helper'

RSpec.describe 'Embeddings::ContentTypes ⟷ its three readers' do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:user) { create(:user) }

  # A tenant is needed to BUILD the relations, not just to run them: acts_as_tenant
  # applies its scope when the relation is constructed.
  def pending_via_button
    ActsAsTenant.with_tenant(organisation) { Embeddings::PendingEmbeddings.relations_by_model.values.sum(&:count) }
  end

  def pending_via_hub
    Embeddings::IndexHealth.call(organisation: organisation).pending
  end

  def sync_page
    AiSyncStatusService.call(organisation: organisation)
  end

  describe 'derivation: a type the registry loses, every reader loses' do
    before { create_pending_record(:meetings, organisation: organisation, project: project, user: user) }

    # The control, so the three examples below cannot pass by counting nothing at all.
    it 'all three readers see the pending meeting while it is registered' do
      expect(pending_via_button).to eq(1)
      expect(pending_via_hub).to eq(1)
      expect(sync_page[:overview][:pending_embeddings]).to eq(1)
    end

    context 'with meetings removed from the registry' do
      before do
        without_meetings = Embeddings::ContentTypes.entries.reject { |entry| entry.key == :meetings }
        allow(Embeddings::ContentTypes).to receive(:entries).and_return(without_meetings)
      end

      it 'the button no longer enqueues meetings' do
        models = ActsAsTenant.with_tenant(organisation) { Embeddings::PendingEmbeddings.relations_by_model.keys }

        expect(models).not_to include(Meeting)
        expect(pending_via_button).to eq(0)
      end

      it 'the hub figure no longer counts the pending meeting' do
        expect(pending_via_hub).to eq(0)
      end

      it 'the sync page has no meetings row and no longer counts the meeting' do
        result = sync_page

        expect(result[:projects].first[:by_type]).not_to have_key(:meetings)
        expect(result[:overview][:pending_embeddings]).to eq(0)
      end
    end
  end

  describe 'behaviour: the three readers agree on one pending record of every type' do
    # Pinned against the registry, not the other way round: a tenth type without a
    # builder in EmbeddableContentTypesHelpers fails HERE, before any example could
    # quietly skip it.
    it 'has a builder for every registered type' do
      Embeddings::ContentTypes.entries.each do |entry|
        expect { create_pending_record(entry.key, organisation: organisation, project: project, user: user) }
          .not_to raise_error, entry.key.inspect
      end
    end

    Embeddings::ContentTypes.entries.map(&:key).each do |key|
      it "agrees on a pending #{key} record" do
        create_pending_record(key, organisation: organisation, project: project, user: user)

        expect(pending_via_button).to eq(1)
        expect(pending_via_hub).to eq(1)
        page = sync_page
        expect(page[:overview][:pending_embeddings]).to eq(1)
        expect(page[:projects].first[:by_type][key][:pending_embeddings]).to eq(1)
      end
    end

    # The overview tiles are the SUM of the project rows, so they depend on
    # Organisation#projects handing back EVERY project. The service argues that in a
    # comment ("no default scope, archived ones included") and nothing held it: a later
    # `.active` there, or a default_scope on Project, drops an archived project's
    # backlog out of the tiles while the summary right above them (IndexHealth, org-wide,
    # no project join) keeps counting it. That is the page contradicting itself again,
    # which is the one thing this strand exists to stop.
    it 'keeps an archived project in the sum the tiles show' do
      create_pending_record(:notes, organisation: organisation, project: project, user: user)
      ActsAsTenant.with_tenant(organisation) { project.update!(archived_at: Time.current) }

      expect(pending_via_hub).to eq(1)
      expect(sync_page[:overview][:pending_embeddings]).to eq(pending_via_hub)
    end

    it 'agrees on an organisation with nothing in it' do
      expect(pending_via_hub).to eq(pending_via_button)
      expect(sync_page[:overview][:pending_embeddings]).to eq(0)
    end

    it 'agrees across the flag, including the FALSE that is not NULL' do
      ActsAsTenant.with_tenant(organisation) do
        create(:note, project: project, organisation: organisation, creator: user,
                      create_embeddings: true, embeddings_creation_flag: true)
        create(:note, project: project, organisation: organisation, creator: user,
                      create_embeddings: true, embeddings_creation_flag: false)
      end

      expect(pending_via_hub).to eq(1)
      expect(pending_via_button).to eq(1)
      expect(sync_page[:overview][:pending_embeddings]).to eq(1)
    end

    # A record carrying an error is FAILED, not pending, for the two COUNTING readers —
    # the page must not say "1 wartend" over a summary that says "1 fehlgeschlagen".
    # The button disagrees on purpose: it hands failures out again so a retry is
    # possible. This example pins the DIFFERENCE, so it stays a decision rather than
    # becoming a surprise.
    it 'differs on a failed record, and that difference is deliberate' do
      ActsAsTenant.with_tenant(organisation) do
        create(:note, project: project, organisation: organisation, creator: user,
                      create_embeddings: true, embeddings_creation_flag: false,
                      embedding_creation_error: 'boom')
      end

      expect(pending_via_hub).to eq(0)
      page = sync_page
      expect(page[:overview][:pending_embeddings]).to eq(0)
      expect(page[:overview][:embedding_errors]).to eq(1)
      expect(pending_via_button).to eq(1)
    end
  end
end
