# frozen_string_literal: true

require 'rails_helper'

# Actors::SaveMeeting — the meetings write seam (Tier 1).
# Intent per describe:
#  - create: persists with the acting user as creator (the controller never
#    passes creator via params — the actor owns that assignment).
#  - update guards: an id that matches nothing in the tenant (foreign tenant or
#    deleted record) must yield a clean failure result, never a raise-through —
#    this path is unreachable via the controller (set_meeting 404s first), so it
#    can ONLY be covered here.
#  - invalid params: failure result, nothing persisted.
RSpec.describe Actors::SaveMeeting do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:user) { create(:user) }

  let(:valid_params) { { title: 'Kickoff', occurred_at: Time.current } }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'create' do
    it 'persists the meeting with the acting user as creator' do
      result = described_class.call(project: project, params: valid_params, current_user: user)

      expect(result.success).to be(true)
      meeting = project.meetings.find_by(title: 'Kickoff')
      expect(meeting.creator).to eq(user)
    end

    it 'returns a failure result and persists nothing for invalid params' do
      result = nil
      expect do
        result = described_class.call(project: project, params: { title: '', occurred_at: nil }, current_user: user)
      end.not_to change(Meeting, :count)
      expect(result.success).to be(false)
    end
  end

  describe 'update lookup guards' do
    it 'fails cleanly when the id matches no meeting in the tenant (foreign tenant / deleted)' do
      other_org = create(:organisation)
      foreign_meeting = ActsAsTenant.with_tenant(other_org) do
        other_project = create(:project, organisation: other_org)
        create(:meeting, project: other_project, organisation: other_org, creator: user)
      end

      result = described_class.call(project: project, params: valid_params,
                                    id: foreign_meeting.id, current_user: user)

      expect(result.success).to be(false)
      expect(ActsAsTenant.with_tenant(other_org) { foreign_meeting.reload.title }).not_to eq('Kickoff')
    end
  end

  describe 'participant sync' do
    def org_member(_name = nil)
      u = create(:user)
      role = create(:role, title: "R#{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: u, organisation: organisation, role: role, active: true)
      u
    end

    def participants_of(meeting)
      meeting.meeting_participants.pluck(:normalized_name).sort
    end

    it 'creates participants from the payload' do
      params = valid_params.merge(participants: [{ display_name: 'Karl Krause' }, { display_name: 'Anna Ananas' }])
      result = described_class.call(project: project, params: params, current_user: user)

      expect(result.success).to be(true)
      expect(participants_of(result.resource)).to eq(['anna ananas', 'karl krause'])
    end

    it 'adds, removes and keeps on update (no orphans)' do
      meeting = described_class.call(
        project: project, params: valid_params.merge(participants: [{ display_name: 'Karl Krause' }, { display_name: 'Anna Ananas' }]),
        current_user: user
      ).resource

      described_class.call(
        project: project, id: meeting.id,
        params: valid_params.merge(participants: [{ display_name: 'Karl Krause' }, { display_name: 'Bert Bauer' }]),
        current_user: user
      )

      expect(participants_of(meeting.reload)).to eq(['bert bauer', 'karl krause'])
    end

    it 'renames in place when the normalized name is unchanged' do
      meeting = described_class.call(
        project: project, params: valid_params.merge(participants: [{ display_name: 'Karl' }]),
        current_user: user
      ).resource

      described_class.call(
        project: project, id: meeting.id,
        params: valid_params.merge(participants: [{ display_name: 'KARL' }]),
        current_user: user
      )

      expect(meeting.reload.meeting_participants.count).to eq(1)
      expect(meeting.meeting_participants.first.display_name).to eq('KARL')
    end

    it 'leaves participants untouched when no :participants key is sent' do
      meeting = described_class.call(
        project: project, params: valid_params.merge(participants: [{ display_name: 'Karl Krause' }]),
        current_user: user
      ).resource

      described_class.call(project: project, id: meeting.id,
                           params: { title: 'Renamed', occurred_at: Time.current }, current_user: user)

      expect(participants_of(meeting.reload)).to eq(['karl krause'])
    end

    it 'clears all participants for an empty payload' do
      meeting = described_class.call(
        project: project, params: valid_params.merge(participants: [{ display_name: 'Karl Krause' }]),
        current_user: user
      ).resource

      described_class.call(project: project, id: meeting.id,
                           params: valid_params.merge(participants: []), current_user: user)

      expect(meeting.reload.meeting_participants).to be_empty
    end

    # The SlimSelect mirror posts an INDEXED hash (meeting[participants][i][...]) with
    # a static blank index-0 sentinel row. These lock in that exact wire shape against
    # the array/hash-tolerant extractor (Option C) so a frontend rework can't silently
    # break the save contract.
    it 'accepts the indexed hash payload from the SlimSelect mirror and drops the blank sentinel row' do
      params = valid_params.merge(participants: { '0' => { 'display_name' => '' },
                                                  '1' => { 'display_name' => 'Karl Krause', 'user_id' => '' } })
      result = described_class.call(project: project, params: params, current_user: user)

      expect(result.success).to be(true)
      expect(participants_of(result.resource)).to eq(['karl krause'])
    end

    it 'clears all when only the blank sentinel row is sent (everyone removed in the UI)' do
      meeting = described_class.call(
        project: project, params: valid_params.merge(participants: [{ display_name: 'Karl Krause' }]),
        current_user: user
      ).resource

      described_class.call(project: project, id: meeting.id,
                           params: valid_params.merge(participants: { '0' => { 'display_name' => '' } }),
                           current_user: user)

      expect(meeting.reload.meeting_participants).to be_empty
    end

    it 'links an internal org member via user_id' do
      member = org_member
      params = valid_params.merge(participants: [{ display_name: 'Member Name', user_id: member.id }])
      meeting = described_class.call(project: project, params: params, current_user: user).resource

      expect(meeting.meeting_participants.first.user_id).to eq(member.id)
    end

    it 'drops a foreign (non-org) user_id to an external name (tamper guard)' do
      outsider = create(:user) # never made an org member
      params = valid_params.merge(participants: [{ display_name: 'Outsider', user_id: outsider.id }])
      meeting = described_class.call(project: project, params: params, current_user: user).resource

      participant = meeting.meeting_participants.first
      expect(participant.user_id).to be_nil
      expect(participant.display_name).to eq('Outsider')
    end

    it 'fails with a readable error on a duplicate name and persists nothing' do
      params = valid_params.merge(participants: [{ display_name: 'Jörg' }, { display_name: 'Joerg' }])

      result = nil
      expect { result = described_class.call(project: project, params: params, current_user: user) }
        .not_to change(MeetingParticipant, :count)
      expect(result.success).to be(false)
      expect(result.errors.join).to match(/doppelt|zweimal|twice|more than once/i)
    end

    it 'fails when the same org member appears twice under different names' do
      member = org_member
      params = valid_params.merge(participants: [
                                    { display_name: 'Karl Krause', user_id: member.id },
                                    { display_name: 'Karl', user_id: member.id }
                                  ])

      result = described_class.call(project: project, params: params, current_user: user)
      expect(result.success).to be(false)
    end
  end

  # Search & chat embedding wiring (Gespräche Slice 6): enqueue gating mirrors
  # SaveNote; the toggle-OFF fragment purge is Meeting-specific (PII data class).
  describe 'search & chat embedding wiring (Slice 6)' do
    let(:content_params) { { title: 'Kickoff', occurred_at: Time.current, notes: 'Wichtige Notizen zum Gespräch.' } }

    def fragment_for(meeting)
      create(:fragment, fragmentable: meeting, organisation: organisation,
                        plain_text_content: 'chunk')
    end

    describe 'enqueue gating' do
      before { allow(EmbeddingProcessingJob).to receive(:perform_later) }

      it 'enqueues the embedding job when the opt-in is on' do
        actor = described_class.new(project: project, params: content_params.merge(create_embeddings: true), current_user: user)
        actor.call
        expect(EmbeddingProcessingJob).to have_received(:perform_later).with(
          record_class: Meeting, record_id: actor.record.id, fragment_association: :fragments
        )
      end

      it 'does NOT enqueue when the opt-in is off' do
        described_class.call(project: project, params: content_params.merge(create_embeddings: false), current_user: user)
        expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
      end

      it 'does NOT enqueue on a validation failure even with the opt-in on' do
        described_class.call(project: project, params: { title: '', occurred_at: nil, create_embeddings: true }, current_user: user)
        expect(EmbeddingProcessingJob).not_to have_received(:perform_later)
      end

      # Cost gate (review PR #247): every run is metered (#231) — an edit that does
      # not change the indexed text must not re-embed the whole transcript.
      it 'does NOT re-enqueue on a content-unchanged update while the opt-in stays on' do
        meeting = described_class.call(project: project, params: content_params.merge(create_embeddings: true), current_user: user).resource

        described_class.call(project: project, id: meeting.id,
                             params: content_params.merge(title: 'Umbenannt', create_embeddings: true), current_user: user)

        expect(EmbeddingProcessingJob).to have_received(:perform_later).once
      end

      it 're-enqueues when the opt-in is re-enabled without a content change' do
        meeting = described_class.call(project: project, params: content_params.merge(create_embeddings: true), current_user: user).resource
        described_class.call(project: project, id: meeting.id,
                             params: content_params.merge(create_embeddings: false), current_user: user)

        described_class.call(project: project, id: meeting.id,
                             params: content_params.merge(create_embeddings: true), current_user: user)

        expect(EmbeddingProcessingJob).to have_received(:perform_later).twice
      end
    end

    describe 'fragment purge on opt-out (PII fail-safe)' do
      before { allow(EmbeddingProcessingJob).to receive(:perform_later) }

      it 'deletes fragments and resets the status columns when the opt-in is turned off' do
        meeting = described_class.call(project: project, params: content_params.merge(create_embeddings: true), current_user: user).resource
        fragment_for(meeting)
        meeting.update!(embeddings_creation_flag: true, embedding_creation_error: 'stale')

        described_class.call(project: project, id: meeting.id,
                             params: content_params.merge(create_embeddings: false), current_user: user)

        expect(meeting.reload.fragments).to be_empty
        expect(meeting.read_attribute(:embeddings_creation_flag)).to be_nil
        expect(meeting.read_attribute(:embedding_creation_error)).to be_nil
      end

      # Matrix row 3 (embedding v2 PR 2): the opt-out purge must take the fragments'
      # sidecar rows with them, synchronously in the actor transaction (PII).
      it 'also purges the fragments\' sidecar content_embeddings rows (no orphan PII)' do
        meeting = described_class.call(project: project, params: content_params.merge(create_embeddings: true), current_user: user).resource
        fragment = fragment_for(meeting)
        create(:content_embedding, organisation: organisation, embeddable: fragment)

        described_class.call(project: project, id: meeting.id,
                             params: content_params.merge(create_embeddings: false), current_user: user)

        expect(meeting.reload.fragments).to be_empty
        expect(ContentEmbedding.where(embeddable: fragment)).to be_empty
      end

      it 'deletes fragments when content is cleared even if the opt-in stays on' do
        meeting = described_class.call(project: project, params: content_params.merge(create_embeddings: true), current_user: user).resource
        fragment_for(meeting)

        described_class.call(project: project, id: meeting.id,
                             params: { title: 'Kickoff', occurred_at: Time.current, notes: '', transcript: '', create_embeddings: true },
                             current_user: user)

        expect(meeting.reload.fragments).to be_empty
      end

      it 'keeps fragments when the opt-in stays on with content present' do
        meeting = described_class.call(project: project, params: content_params.merge(create_embeddings: true), current_user: user).resource
        fragment_for(meeting)

        described_class.call(project: project, id: meeting.id,
                             params: content_params.merge(create_embeddings: true, notes: 'Aktualisierte Notizen.'), current_user: user)

        expect(meeting.reload.fragments).not_to be_empty
      end
    end
  end
end
