# frozen_string_literal: true

require 'rails_helper'

# Meetings::TicketSuggestionService — the async ticket-suggestion generator.
#
# Intent: prove the hostile-model hardening (JSON shape whitelist + caps), the
# HALLUCINATION GUARD (an LLM-supplied ticket id can never become similar_ticket —
# the match is computed only from our own embeddings, E22), the cosine threshold
# boundary, and the 2A run semantics (parse/match outside the txn; a failed run
# leaves the existing open suggestions untouched; accepted/dismissed always stay).
# All LLM + embedding traffic is stubbed at the Factory / QueryEmbedding seam.
#
# Since embedding v2 PR 4b the candidate pool comes from the content_embeddings
# sidecar via Embeddings::NearestNeighbors, so every seeded ticket fragment mirrors
# its vector there (mirror_embedding_to_sidecar) — an inline-only seed would produce
# no candidates and every matching example would pass for the wrong reason.
RSpec.describe Meetings::TicketSuggestionService do
  let(:organisation) { create(:organisation, ai_enabled: true) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user, organisation: organisation) }

  let(:transcript) { 'Anna: Wir müssen die Rechnung an Kunde X senden und das Angebot prüfen.' }
  let(:notes) { nil }
  let(:meeting) do
    create(:meeting, organisation: organisation, project: project, creator: user,
                     transcript: transcript, notes: notes, suggestions_creation_flag: true)
  end

  let(:provider) { double('llm_provider') }
  let(:llm_content) { '[{"title":"Rechnung senden","description":"An Kunde X"},{"title":"Angebot prüfen","description":"Konditionen"}]' }
  let(:chat_result) { { content: llm_content, token_usage: { total_tokens: 100 }, model_used: 'gpt-4o-mini' } }

  before do
    ActsAsTenant.current_tenant = organisation
    stub_default_embedding_space
    pin_exact_vector_scans
    allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:meeting_ticket_suggestions, organisation).and_return(provider)
    allow(provider).to receive(:chat).and_return(chat_result)
    allow(Lalabase::Llm::UsageTracking).to receive(:record)
    # Default: no real embedding, no match — matching tests opt in with a real vector.
    allow(Lalabase::QueryEmbedding).to receive(:embed).and_return(nil)
  end

  after { ActsAsTenant.current_tenant = nil }

  def open_suggestions
    meeting.reload.meeting_ticket_suggestions.open
  end

  describe 'success' do
    it 'creates the open suggestions and clears the run status' do
      expect { described_class.call(meeting: meeting) }
        .to change { meeting.meeting_ticket_suggestions.open.count }.from(0).to(2)

      expect(open_suggestions.pluck(:title)).to contain_exactly('Rechnung senden', 'Angebot prüfen')
      expect(meeting.suggestions_creation_flag).to be(false)
      expect(meeting.suggestions_creation_error).to eq('')
    end

    it 'uses the meeting summary_source (transcript preferred) as the LLM input' do
      sent = nil
      allow(provider).to receive(:chat) do |**kwargs|
        sent = kwargs[:messages].first[:content]
        chat_result
      end
      described_class.call(meeting: meeting)
      expect(sent).to include('Rechnung an Kunde X')
    end
  end

  describe 'parse whitelist (hostile-model hardening)' do
    context 'with blank titles, non-objects and messy whitespace' do
      let(:llm_content) do
        '[{"title":"Gut","description":"ok"},{"title":"","description":"leer"},' \
          '{"description":"kein Titel"},"not an object",{"title":"  Mit   Spaces  ","description":"x"}]'
      end

      it 'keeps only well-shaped entries and collapses title whitespace' do
        described_class.call(meeting: meeting)
        expect(open_suggestions.pluck(:title)).to contain_exactly('Gut', 'Mit Spaces')
      end
    end

    context 'with code fences and a {"suggestions": [...]} wrapper' do
      let(:llm_content) { "```json\n{\"suggestions\":[{\"title\":\"X\",\"description\":\"y\"}]}\n```" }

      it 'strips the fences and unwraps' do
        described_class.call(meeting: meeting)
        expect(open_suggestions.pluck(:title)).to eq(['X'])
      end
    end

    context 'with more than MAX_SUGGESTIONS entries' do
      let(:llm_content) { (1..15).map { |i| { title: "T#{i}", description: 'd' } }.to_json }

      it 'caps the count at MAX_SUGGESTIONS' do
        described_class.call(meeting: meeting)
        expect(open_suggestions.count).to eq(described_class::MAX_SUGGESTIONS)
      end
    end

    context 'with an oversized title' do
      let(:llm_content) { [{ title: 'a' * 300, description: 'd' }].to_json }

      it 'caps the title at 255 chars' do
        described_class.call(meeting: meeting)
        expect(open_suggestions.first.title.length).to eq(255)
      end
    end
  end

  describe 'hallucination guard (E22): LLM-supplied ids are ignored' do
    let(:foreign_ticket) { create(:ticket, project: project, organisation: organisation) }
    let(:llm_content) do
      [{ title: 'X', description: 'y', ticket_id: foreign_ticket.id, id: 999,
         similar_ticket_id: foreign_ticket.id }].to_json
    end

    it 'never adopts an id from the LLM — similar_ticket comes only from the NN search' do
      described_class.call(meeting: meeting)
      suggestion = open_suggestions.first
      expect(suggestion.title).to eq('X')
      # embed returns nil here → no NN match → nil, NOT the injected foreign id.
      expect(suggestion.similar_ticket_id).to be_nil
    end
  end

  describe 'server-side similarity matching (cosine boundary 0.81)' do
    let(:llm_content) { '[{"title":"Match","description":"desc"}]' }
    # Query = unit vector along axis 0; a unit candidate’s cosine with it is just its
    # first component, so we dial the boundary precisely.
    let(:query_vec) { [1.0] + Array.new(1535, 0.0) }
    let(:existing_ticket) { create(:ticket, project: project, organisation: organisation) }

    before { allow(Lalabase::QueryEmbedding).to receive(:embed).and_return(query_vec) }

    def ticket_fragment_with_cosine(cosine, ticket: existing_ticket)
      vec = [cosine, Math.sqrt(1 - (cosine**2))] + Array.new(1534, 0.0)
      fragment = create(:fragment, fragmentable: ticket, organisation: organisation)
      seed_sidecar_embedding(fragment, vector: vec)
      fragment
    end

    it 'sets similar_ticket_id when the best candidate clears 0.81 (0.82)' do
      ticket_fragment_with_cosine(0.82)
      described_class.call(meeting: meeting)
      expect(open_suggestions.first.similar_ticket_id).to eq(existing_ticket.id)
    end

    it 'leaves similar_ticket_id nil when the best candidate is below 0.81 (0.80)' do
      ticket_fragment_with_cosine(0.80)
      described_class.call(meeting: meeting)
      expect(open_suggestions.first.similar_ticket_id).to be_nil
    end

    it 'does not match a ticket fragment from ANOTHER project (project-scoped)' do
      other_project = create(:project, organisation: organisation)
      other_ticket = create(:ticket, project: other_project, organisation: organisation)
      ticket_fragment_with_cosine(0.95, ticket: other_ticket)

      described_class.call(meeting: meeting)
      expect(open_suggestions.first.similar_ticket_id).to be_nil
    end
  end

  describe 'run semantics (2A: atomic replace, failure leaves open untouched)' do
    it 'replaces only OPEN suggestions; accepted/dismissed stay as history' do
      old_open = create(:meeting_ticket_suggestion, meeting: meeting)
      accepted = create(:meeting_ticket_suggestion, :accepted, meeting: meeting)
      dismissed = create(:meeting_ticket_suggestion, :dismissed, meeting: meeting)

      described_class.call(meeting: meeting)

      expect(MeetingTicketSuggestion.exists?(old_open.id)).to be(false)
      expect(MeetingTicketSuggestion.exists?(accepted.id)).to be(true)
      expect(MeetingTicketSuggestion.exists?(dismissed.id)).to be(true)
      expect(open_suggestions.pluck(:title)).to contain_exactly('Rechnung senden', 'Angebot prüfen')
    end

    context 'when the JSON is unparseable' do
      let(:llm_content) { 'total garbage {{{ not json' }

      it 'leaves the existing open suggestions untouched and records parse_error' do
        old_open = create(:meeting_ticket_suggestion, meeting: meeting)

        described_class.call(meeting: meeting)

        expect(MeetingTicketSuggestion.exists?(old_open.id)).to be(true)
        expect(meeting.reload.suggestions_creation_error)
          .to eq(I18n.t('services.meetings.ticket_suggestions.parse_error'))
        expect(meeting.suggestions_creation_flag).to be(false)
      end
    end

    # Checked before the JSON is parsed: even an answer that happens to parse
    # (cut right after a closing bracket) is not the list the model meant to give.
    context 'when the answer was cut at the output limit' do
      let(:chat_result) { { content: llm_content, stop_reason: 'length', token_usage: { total_tokens: 100 }, model_used: 'gpt-4o-mini' } }

      it 'creates and deletes no suggestion, records the truncated error and still meters' do
        old_open = create(:meeting_ticket_suggestion, meeting: meeting)

        expect { described_class.call(meeting: meeting) }.not_to(change { meeting.meeting_ticket_suggestions.count })

        expect(MeetingTicketSuggestion.exists?(old_open.id)).to be(true)
        expect(meeting.reload.suggestions_creation_error)
          .to eq(I18n.t('services.meetings.ticket_suggestions.truncated'))
        expect(meeting.suggestions_creation_flag).to be(false)
        expect(Lalabase::Llm::UsageTracking).to have_received(:record)
      end
    end

    context 'when the answer of an assistant-started run was cut at the output limit' do
      let(:chat_result) { { content: llm_content, stop_reason: 'length', token_usage: { total_tokens: 100 }, model_used: 'gpt-4o-mini' } }
      let(:run) do
        MeetingTicketSuggestionRun.create!(
          organisation: organisation, meeting: meeting, project_id: meeting.project_id, status: :running,
          meeting_title: meeting.title, project_title: project.name, job_id: SecureRandom.uuid,
          results: [], sources: {}
        )
      end

      it 'fails the run with the truncated message and creates no suggestion' do
        expect { described_class.call(meeting: meeting, run: run) }
          .not_to(change { meeting.meeting_ticket_suggestions.count })

        expect(run.reload).to be_failed
        expect(run.error).to eq(I18n.t('services.meetings.ticket_suggestions.truncated'))
        expect(meeting.reload.suggestions_creation_flag).to be(false)
      end
    end

    context 'when the quota is exhausted (Factory raises)' do
      before { allow(Lalabase::Llm::Factory).to receive(:for_feature).with(:meeting_ticket_suggestions, organisation).and_raise(Lalabase::Llm::QuotaExceededError) }

      it 'leaves the existing open suggestions untouched and records the quota error' do
        old_open = create(:meeting_ticket_suggestion, meeting: meeting)

        expect { described_class.call(meeting: meeting) }.not_to raise_error

        expect(MeetingTicketSuggestion.exists?(old_open.id)).to be(true)
        expect(meeting.reload.suggestions_creation_error)
          .to eq(I18n.t('services.meetings.ticket_suggestions.quota_exhausted'))
        expect(meeting.suggestions_creation_flag).to be(false)
      end
    end
  end

  describe 'metering (F14: 1× ticket_suggestions + N× semantic_search)' do
    let(:llm_content) { '[{"title":"A","description":"x"},{"title":"B","description":"y"},{"title":"C","description":"z"}]' }

    it 'books the flat ticket_suggestions action once for the run, with the meeting subject' do
      expect(Lalabase::Llm::UsageTracking).to receive(:record).with(
        hash_including(action: Lalabase::Llm::ActionRegistry::TICKET_SUGGESTIONS,
                       subject: meeting, call_type: 'meeting_ticket_suggestions')
      )
      described_class.call(meeting: meeting)
    end

    it 'embeds once per suggestion (each QueryEmbedding.embed self-meters semantic_search)' do
      expect(Lalabase::QueryEmbedding).to receive(:embed).exactly(3).times.and_return(nil)
      described_class.call(meeting: meeting)
    end
  end

  describe 'gate + no-source wiring (inherited from BaseLlmService)' do
    context 'with neither transcript nor notes' do
      let(:transcript) { nil }

      it 'does not call the LLM and clears the pending flag' do
        expect(Lalabase::Llm::Factory).not_to receive(:for_feature)
        described_class.call(meeting: meeting)
        expect(meeting.reload.suggestions_creation_flag).to be(false)
        expect(meeting.meeting_ticket_suggestions.count).to eq(0)
      end
    end

    context 'when AI is disabled for the organisation' do
      let(:organisation) { create(:organisation, ai_enabled: false) }

      it 'does not call the LLM and records the ai_disabled error' do
        expect(Lalabase::Llm::Factory).not_to receive(:for_feature)
        described_class.call(meeting: meeting)
        expect(meeting.reload.suggestions_creation_error)
          .to eq(I18n.t('services.meetings.ticket_suggestions.ai_disabled'))
        expect(meeting.suggestions_creation_flag).to be(false)
      end
    end
  end

  describe 'provider routing follows the org choice (S1b)' do
    let(:run_service) { -> { described_class.call(meeting: meeting) } }
    let(:metered_subject) { meeting }
    let(:assert_run_succeeded) do
      -> { expect(meeting.reload.meeting_ticket_suggestions.open.count).to eq(2) }
    end

    it_behaves_like 'a meeting LLM service routed by the org chat choice',
                    call_type: 'meeting_ticket_suggestions',
                    feature_key: :meeting_ticket_suggestions,
                    action: Lalabase::Llm::ActionRegistry::TICKET_SUGGESTIONS
  end
end
