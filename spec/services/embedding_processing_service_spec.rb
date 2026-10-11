# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmbeddingProcessingService do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:ticket) do
    create(:ticket, project: project, organisation: organisation, creator: user)
  end
  # Note uses DB-backed embeddings_creation_flag (unlike Ticket which overrides it to always true)
  let(:note) do
    create(:note, project: project, organisation: organisation, creator: user,
                  create_embeddings: true, plain_text_version: 'Dies ist ein Test-Inhalt für die Note.')
  end
  let(:fake_embedding) { Array.new(1536) { rand(-1.0..1.0) } }
  # The write path resolves ONE embedding provider per run via the Factory; we
  # stub that seam so both #generate_embedding and the provenance stamp in
  # #create_fragment (which reads provider_name/default_embedding_model) work.
  let(:embed_provider) do
    instance_double(Lalabase::Llm::OpenAiProvider, billing_credential: nil,
                                                   embed_with_usage: { embedding: fake_embedding, total_tokens: 10 },
                                                   provider_name: 'openai',
                                                   default_embedding_model: 'text-embedding-3-small',
                                                   expected_embedding_dims: 1536)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    Current.user = user
    allow(Lalabase::Llm::Factory).to receive(:for_embeddings).and_return(embed_provider)
  end

  around do |example|
    ActsAsTenant.with_tenant(organisation) do
      example.run
    end
  end

  describe '#initialize' do
    it 'uses the provided fragment_association' do
      service = described_class.new(ticket, :custom_fragments)
      expect(service.fragment_association).to eq(:custom_fragments)
    end

    it 'defaults to :fragments' do
      service = described_class.new(ticket)
      expect(service.fragment_association).to eq(:fragments)
    end

    it 'falls back to default_fragment_association when nil is passed' do
      service = described_class.new(ticket, nil)
      expect(service.fragment_association).to eq(:fragments)
    end
  end

  # ⚠️ Clearing the error is part of succeeding. Without it a record that failed once
  # stayed "failed" forever, because every reader of "how much failed" counts the COLUMN,
  # not the flag — while Embeddings::PendingEmbeddings selects on the FLAG. The pair is
  # what makes the state unreachable: the successful retry set the flag, so the record
  # left the pending set, but kept the error, so it never left the failed set. On the
  # Indexierung page (KI-Bereich S4) that reads as a permanent red "Es sind Fehler
  # aufgetreten" above a "Neu verarbeiten" button that enqueues nothing.
  describe 'a retry after a failure' do
    it 'clears the recorded error instead of leaving the record failed forever' do
      note.update_columns(embeddings_creation_flag: false, embedding_creation_error: 'boom')

      described_class.new(note).process

      expect(note.reload).to have_attributes(embeddings_creation_flag: true,
                                             embedding_creation_error: nil)
    end

    # The half that makes the alarm unreachable rather than merely stale: after the
    # successful retry the record is no longer pending, so the button the page offers has
    # nothing left to enqueue for it.
    it 'leaves the record out of the pending set it was rescued from' do
      note.update_columns(embeddings_creation_flag: false, embedding_creation_error: 'boom')

      described_class.new(note).process

      pending_ids = Embeddings::PendingEmbeddings.relations_by_model[Note].pluck(:id)
      expect(pending_ids).not_to include(note.id)
    end
  end

  describe '#process' do
    # GDPR AI opt-in (audit 2026-07-03): a non-opted-in org must not have its
    # content embedded. The service skips BEFORE touching the factory — no
    # error flag, no exception, so jobs complete quietly instead of retrying.
    context 'when the organisation has not opted in to AI (GDPR gate)' do
      before { organisation.update!(ai_enabled: false) }

      # CHANGED by the fragment/embedding split (S3 of
      # doc/fragment_einbettung_entkopplung_plan.md). The gate is the GDPR opt-in and it
      # guards the TRANSFER, which is the thing that needs consent. Extraction is local
      # text processing and now runs regardless — before the split an organisation that
      # never enabled AI had no searchable posts or notes AT ALL, which was a consequence
      # nobody chose.
      it 'extracts fragments but never resolves an embedding provider' do
        expect { described_class.new(ticket).process }.to change(Fragment, :count).by(1)
        expect(Lalabase::Llm::Factory).not_to have_received(:for_embeddings)
      end

      it 'writes no vector for them, so nothing was transferred' do
        described_class.new(ticket).process
        fragment_ids = ticket.fragments.reload.map(&:id)
        expect(fragment_ids).not_to be_empty
        expect(ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: fragment_ids)).to be_empty
      end

      it 'does not raise and does not flag the record as failed' do
        expect { described_class.new(note).process }.not_to raise_error
        expect(note.reload.read_attribute(:embeddings_creation_flag)).not_to be true
        expect(note.embedding_creation_error).to be_blank
      end

      it 'also skips quietly for a record without an organisation (fail-closed nil branch)' do
        # The guard uses `record.organisation&.ai_enabled?` — a nil org must
        # mean "no embedding" (fail-closed), never a NoMethodError or an
        # accidental fall-through to the provider.
        orphan = Struct.new(:organisation, :plain_text_version, :id).new(nil, 'text', 'orphan-1')

        expect { described_class.new(orphan, :fragments).process }.not_to raise_error
        expect(Lalabase::Llm::Factory).not_to have_received(:for_embeddings)
      end

      it 'leaves fragments from before the deactivation fully intact (skip fires before rebuild)' do
        # Functional-block guard: process normally rebuilds fragments and
        # deletes the old version set. If the opt-in check ever moved BELOW
        # the rebuild (e.g. only guarding the API call), a disabled org would
        # lose its existing local fragments. They are local data and must
        # survive deactivation untouched.
        organisation.update!(ai_enabled: true)
        described_class.new(ticket).process
        surviving_ids = ticket.fragments.order(:id).pluck(:id)
        expect(surviving_ids).not_to be_empty

        organisation.update!(ai_enabled: false)
        described_class.new(ticket).process

        expect(ticket.fragments.order(:id).pluck(:id)).to eq(surviving_ids)
      end
    end

    context 'happy path' do
      before do
        allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
      end

      it 'creates fragments from the record plain_text_version' do
        expect { described_class.new(ticket).process }.to change(Fragment, :count).by_at_least(1)
      end

      it 'sets embeddings_creation_flag to true on success (Note model)' do
        described_class.new(note).process
        expect(note.reload.read_attribute(:embeddings_creation_flag)).to be true
      end

      it 'assigns a version_token to all created fragments' do
        described_class.new(ticket).process
        tokens = ticket.fragments.pluck(:version_token).uniq
        expect(tokens.size).to eq(1)
        expect(tokens.first).to be_present
      end

      it 'stores the embedding vector for each fragment (in the sidecar)' do
        described_class.new(ticket).process
        expect(ticket.fragments).to be_present # guards against a vacuous loop below
        ticket.fragments.each do |fragment|
          expect(ContentEmbedding.find_by(embeddable: fragment)&.embedding).to be_present
        end
      end

      it 'stores the plain text content on each fragment' do
        described_class.new(ticket).process
        ticket.fragments.each do |fragment|
          expect(fragment.plain_text_content).to be_present
        end
      end

      it 'assigns the correct organisation to fragments' do
        described_class.new(ticket).process
        ticket.fragments.each do |fragment|
          expect(fragment.organisation_id).to eq(organisation.id)
        end
      end
    end

    context 'when record does not respond to plain_text_version' do
      let(:record_without_plain_text) { double('Record') }

      # A record that answers NO to every one of these questions, which is the honest
      # shape of "this thing is not indexable". Stubbing only :plain_text_version made the
      # double raise the moment the service asked a second question — since S4 it asks
      # about the flag column too, to decide whether it may settle the record as done.
      before do
        allow(record_without_plain_text).to receive(:respond_to?).and_return(false)
      end

      it 'returns nil without creating fragments' do
        result = described_class.new(record_without_plain_text).process
        expect(result).to be_nil
      end

      # It must not try to settle what it cannot settle: with no flag column there is
      # nothing to write, and reaching for one would raise inside a quiet skip.
      it 'writes nothing at all' do
        expect(record_without_plain_text).not_to receive(:update)
        expect(record_without_plain_text).not_to receive(:update_columns)
        described_class.new(record_without_plain_text).process
      end
    end

    context 'when plain_text_version is blank' do
      before do
        allow(ticket).to receive(:plain_text_version).and_return('')
      end

      it 'returns nil without creating fragments' do
        result = described_class.new(ticket).process
        expect(result).to be_nil
        expect(Fragment.count).to eq(0)
      end
    end

    context 'when plain_text_version is nil' do
      before do
        allow(ticket).to receive(:plain_text_version).and_return(nil)
      end

      it 'returns nil without creating fragments' do
        result = described_class.new(ticket).process
        expect(result).to be_nil
        expect(Fragment.count).to eq(0)
      end
    end

    context 'with multiple text fragments' do
      # Service loops over fragments, one INSERT per fragment — Prosopite would
      # flag the repeated writes; pause it for this multi-fragment scenario.
      before { Prosopite.pause }

      before do
        allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
        # TextProcessingService splits at ~500 tokens (~375 words).
        # Generate text that definitely exceeds one fragment.
        long_text = 50.times.map do |i|
          "Dies ist Satz Nummer #{i} mit genügend Wörtern um den Token-Zähler pro Fragment deutlich zu erhöhen und sicherzustellen dass der Text in mehrere Fragmente aufgeteilt wird."
        end.join(' ')
        allow(ticket).to receive(:plain_text_version).and_return(long_text)
      end

      it 'creates multiple fragments when text is long' do
        described_class.new(ticket).process
        expect(ticket.fragments.count).to be > 1
      end

      it 'all fragments share the same version_token' do
        described_class.new(ticket).process
        tokens = ticket.fragments.pluck(:version_token).uniq
        expect(tokens.size).to eq(1)
      end
    end

    context 'version rotation (deleting old fragments)' do
      let!(:old_token) { SecureRandom.uuid }

      before do
        allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
        3.times do
          create(:fragment,
                 fragmentable: ticket,
                 organisation: organisation,
                 version_token: old_token)
        end
      end

      it 'deletes old fragments after successful processing' do
        expect(ticket.fragments.where(version_token: old_token).count).to eq(3)

        described_class.new(ticket).process

        expect(ticket.fragments.where(version_token: old_token).count).to eq(0)
      end

      it 'retains only the new fragments' do
        described_class.new(ticket).process
        tokens = ticket.fragments.reload.pluck(:version_token).uniq
        expect(tokens.size).to eq(1)
        expect(tokens.first).not_to eq(old_token)
      end
    end

    context 'when multiple old version tokens exist (edge case)' do
      before do
        allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
        # Simulate two previous incomplete runs with different tokens
        2.times do
          token = SecureRandom.uuid
          create(:fragment,
                 fragmentable: ticket,
                 organisation: organisation,
                 version_token: token)
        end
      end

      it 'deletes all old fragments regardless of how many old token groups exist' do
        old_fragment_ids = ticket.fragments.pluck(:id)
        expect(old_fragment_ids.size).to eq(2)

        described_class.new(ticket).process

        # All old fragments are cleaned up
        remaining_old = ticket.fragments.reload.where(id: old_fragment_ids).count
        expect(remaining_old).to eq(0)
      end
    end

    context 'error handling' do
      context 'when the embedding provider raises an error' do
        before do
          allow(embed_provider).to receive(:embed_with_usage)
            .and_raise(StandardError, 'OpenAI API request failed')
        end

        it 'sets embeddings_creation_flag to false (Note model)' do
          described_class.new(note).process
          expect(note.reload.read_attribute(:embeddings_creation_flag)).to be false
        end

        it 'stores the error message on the record' do
          described_class.new(note).process
          expect(note.reload.embedding_creation_error).to eq('OpenAI API request failed')
        end

        # CHANGED by the split: the fragment is written BEFORE the embedding call, so a
        # provider failure costs the vector and not the searchability. This is the whole
        # point — in production on 2026-08-30, 69 posts had been removed from the search
        # index this way, 43 of them by a transient HTTP 429.
        it 'keeps the fragments, so the content stays full-text searchable' do
          described_class.new(note).process
          expect(note.fragments.reload).not_to be_empty
        end

        it 'writes no vector for them' do
          described_class.new(note).process
          fragment_ids = note.fragments.reload.map(&:id)
          expect(fragment_ids).not_to be_empty
          expect(ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: fragment_ids)).to be_empty
        end

        it 'logs the error' do
          expect(Rails.logger).to receive(:error).with(/Error creating embeddings/)
          described_class.new(note).process
        end
      end

      context 'when TextProcessingService raises an error' do
        before do
          allow_any_instance_of(TextProcessingService).to receive(:split_text_into_fragments)
            .and_raise(StandardError, 'Text splitting failed')
        end

        it 'handles the error gracefully' do
          described_class.new(note).process
          expect(note.reload.read_attribute(:embeddings_creation_flag)).to be false
          expect(note.reload.embedding_creation_error).to eq('Text splitting failed')
        end
      end

      context 'when fragment creation fails' do
        # Service loops over fragments, one INSERT per fragment — pause Prosopite.
        before { Prosopite.pause }

        before do
          allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
          # Force TextProcessingService to return 2 fragments so the second call triggers the error
          allow_any_instance_of(TextProcessingService).to receive(:split_text_into_fragments)
            .and_return(['Fragment eins.', 'Fragment zwei.'])

          call_count = 0
          allow_any_instance_of(described_class).to receive(:create_fragment).and_wrap_original do |method, *args|
            call_count += 1
            raise ActiveRecord::RecordInvalid.new(Fragment.new) if call_count > 1

            method.call(*args)
          end
        end

        it 'marks as failed' do
          described_class.new(note).process
          expect(note.reload.read_attribute(:embeddings_creation_flag)).to be false
        end
      end

      context 'when record does not respond to error attributes' do
        let(:minimal_record) do
          record = double('MinimalRecord',
                          plain_text_version: 'Some text content.',
                          organisation_id: organisation.id,
                          organisation: organisation,
                          id: SecureRandom.uuid)
          allow(record).to receive(:class).and_return(Ticket)
          allow(record).to receive(:respond_to?).with(:plain_text_version).and_return(true)
          allow(record).to receive(:respond_to?).with(:create_embeddings).and_return(false)
          allow(record).to receive(:respond_to?).with(:embeddings_creation_flag).and_return(false)
          allow(record).to receive(:respond_to?).with(:embedding_creation_error).and_return(false)
          allow(record).to receive(:send).with(:fragments).and_raise(StandardError, 'no fragments')
          record
        end

        it 'logs the error without attempting to update columns' do
          expect(Rails.logger).to receive(:error).with(/Error creating embeddings/)
          expect(minimal_record).not_to receive(:update_columns)
          described_class.new(minimal_record).process
        end
      end
    end

    context 'when mark_embeddings_as_successful fails' do
      # A REAL note with ONE targeted stub, not a hand-built double.
      #
      # It used to be a double, and the split made that untenable: extraction now reads the
      # association three more times before the guard under test is reached (the reuse
      # comparison, the unembedded filter, and the version swap, which chains .where.not
      # and .lock). Each read had to be stubbed, and every stub was a second, private
      # description of what the service does — the kind of test that goes red on a
      # refactor that broke nothing. `respond_to?` is the ONE thing this example is about.
      let(:record_without_flag) do
        record = create(:note, project: project, organisation: organisation, creator: user,
                               create_embeddings: true, content: 'Some text.')
        allow(record).to receive(:respond_to?).and_call_original
        allow(record).to receive(:respond_to?).with(:embeddings_creation_flag).and_return(false)
        record
      end

      before do
        allow_any_instance_of(TextProcessingService).to receive(:split_text_into_fragments).and_return(['Some text.'])
        allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
      end

      it 'raises RuntimeError which is caught by error handler and logged' do
        expect(Rails.logger).to receive(:error).with(/does not have an embeddings_creation_flag attribute/)
        described_class.new(record_without_flag).process
      end
    end
  end

  # Write-both (embedding v2 PR 2): each chunk fragment gets a shadow sidecar row,
  # atomically with the fragment (m1).
  describe '#process sidecar write-both' do
    before do
      allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
      allow_any_instance_of(TextProcessingService).to receive(:split_text_into_fragments).and_return(['chunk one'])
    end

    it 'writes one sidecar row per chunk with the triple + source_hash of that chunk' do
      expect { described_class.new(note).process }.to change(ContentEmbedding, :count).by(1)
      frag = note.fragments.first
      row = ContentEmbedding.find_by(embeddable: frag)
      expect(row).to have_attributes(
        organisation_id: organisation.id,
        embedding_provider: 'openai', embedding_model: 'text-embedding-3-small', embedding_dims: 1536,
        source_hash: ContentEmbedding.source_hash_for('chunk one'), indexed: true
      )
      expect(row.embedded_at).to be_present
    end

    # CHANGED, deliberately: the write-both transaction is gone. Its stated reason was
    # "a fragment without a vector is invisible to every reader since PR 4b", and that is
    # false for the full-text reader — search_full_text_german is a pg_search_scope
    # against plain_text_content with no join to content_embeddings. The atomicity was
    # protecting nothing and paid for it with the full-text index.
    # ⚠️ Stubs #save!, not .create!: #attach_embedding became an upsert
    # (find_or_initialize_by + save!) so a de-indexed row in the same space is repaired
    # rather than duplicated. A .create! stub is never reached and this example would
    # pass without exercising anything.
    it 'keeps the chunk fragment when the sidecar write fails' do
      allow(ContentEmbedding).to receive(:find_or_initialize_by) do
        instance_double(ContentEmbedding).tap do |row|
          allow(row).to receive(:assign_attributes)
          allow(row).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(ContentEmbedding.new))
        end
      end
      expect { described_class.new(note).process }.to change(Fragment, :count).by(1)
      expect(note.reload.read_attribute(:embeddings_creation_flag)).to be false
    end
  end

  # Inline write guard (embedding v2 PR 5, sheet §3.2): fragments.embedding is typed
  # vector(1536). Without the guard a 1024-dim org writes the vector inline, pgvector
  # raises "expected 1536 dimensions, not 1024", the whole transaction rolls back and
  # Dimension parity (embedding v2 PR 7). fragments.embedding was typed vector(1536),
  # so a 1024-dim org needed a write guard that left it NULL — without it the whole
  # create! failed and #handle_embedding_error recorded that the org could not embed at
  # all. The column is gone: 1024 and 1536 take the same path into the sidecar, and the
  # examples below are the control pair that breaks if any dimension branch returns.
  describe '#process across dimensions' do
    let(:embedding1024) { Array.new(1024) { rand(-1.0..1.0) } }

    before do
      allow(embed_provider).to receive_messages(
        embed_with_usage: { embedding: embedding1024, total_tokens: 10 },
        provider_name: 'openai_compatible',
        default_embedding_model: 'mistral-embed',
        expected_embedding_dims: 1024
      )
      allow_any_instance_of(TextProcessingService).to receive(:split_text_into_fragments).and_return(['chunk one'])
    end

    it 'creates the fragment with a full 1024 sidecar row' do
      expect { described_class.new(note).process }
        .to change(Fragment, :count).by(1).and change(ContentEmbedding, :count).by(1)

      row = ContentEmbedding.find_by(embeddable: note.fragments.first)
      expect(row).to have_attributes(embedding_provider: 'openai_compatible',
                                     embedding_model: 'mistral-embed', embedding_dims: 1024, indexed: true)
      expect(row.embedding.to_a.length).to eq(1024)
    end

    it 'completes the run without recording an embedding error' do
      described_class.new(note).process

      expect(note.reload.embedding_creation_error).to be_nil
      expect(note.read_attribute(:embeddings_creation_flag)).to be true
    end
  end

  describe '#process with Note model' do
    before do
      allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
    end

    it 'creates fragments for notes' do
      expect { described_class.new(note).process }.to change(Fragment, :count).by_at_least(1)
    end

    it 'associates fragments with the note polymorphically' do
      described_class.new(note).process
      fragment = note.fragments.first
      expect(fragment.fragmentable_type).to eq('Note')
      expect(fragment.fragmentable_id).to eq(note.id)
    end
  end

  # Gespräche Slice 6: a meeting is embedded by the SAME generic service — it just
  # holds the contract (plain_text_version + flag columns + :fragments association).
  describe '#process with Meeting model (Gespräche Slice 6)' do
    let(:meeting) do
      create(:meeting, project: project, organisation: organisation, creator: user,
                       create_embeddings: true, notes: 'Besprochen: Login-Bug und die Reproschritte.')
    end

    before do
      allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
    end

    it 'creates fragments for a meeting via the generic service' do
      expect { described_class.new(meeting).process }.to change(Fragment, :count).by_at_least(1)
    end

    it 'associates fragments with the meeting polymorphically' do
      described_class.new(meeting).process
      fragment = meeting.fragments.first
      expect(fragment.fragmentable_type).to eq('Meeting')
      expect(fragment.fragmentable_id).to eq(meeting.id)
    end

    it 'marks embeddings_creation_flag true on success' do
      described_class.new(meeting).process
      expect(meeting.reload.read_attribute(:embeddings_creation_flag)).to be true
    end

    # Runtime opt-in re-check (review PR #247): a job enqueued while opted IN that
    # runs only AFTER a later opt-OUT must not resurrect the purged fragments — the
    # PII race the synchronous purge in Actors::SaveMeeting cannot cover alone.
    context 'when the opt-in was turned off after the job was enqueued' do
      it 'skips without any writes: no fragments, no provider call, flag stays nil' do
        meeting.update!(create_embeddings: false)

        expect { described_class.new(meeting).process }.not_to change(Fragment, :count)
        expect(embed_provider).not_to have_received(:embed_with_usage)
        expect(meeting.reload.read_attribute(:embeddings_creation_flag)).to be_nil
      end
    end

    # The sharper variant (adversarial review PR #247): the job is already PAST the
    # start guard and mid-loop when the opt-out purge runs — the purge's delete_all
    # only removes rows existing at that instant. The post-run re-check must discard
    # the job's own writes instead of resurrecting purged PII.
    context 'when the opt-in is turned off while the job is mid-run (purge race)' do
      it 'discards the just-written fragments and does not mark the flag' do
        first_call = true
        allow(embed_provider).to receive(:embed_with_usage) do
          meeting.update!(create_embeddings: false) if first_call
          first_call = false
          { embedding: fake_embedding, total_tokens: 10 }
        end

        expect { described_class.new(meeting).process }.not_to(change { meeting.fragments.count })
        expect(meeting.reload.read_attribute(:embeddings_creation_flag)).to be_nil
      end

      # Matrix row 5 (embedding v2 PR 2): the post-run purge must take the sidecar
      # rows THIS run just wrote — otherwise purged PII survives in content_embeddings.
      it 'also purges the sidecar rows the run wrote before the opt-out (no orphan PII)' do
        first_call = true
        allow(embed_provider).to receive(:embed_with_usage) do
          meeting.update!(create_embeddings: false) if first_call
          first_call = false
          { embedding: fake_embedding, total_tokens: 10 }
        end

        described_class.new(meeting).process
        expect(ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: meeting.fragments.select(:id)))
          .to be_empty
        expect(meeting.fragments.count).to eq(0)
      end
    end

    # Destroy-mid-run race (embedding v2 PR 3, carry-over from review #353): the DB
    # row is pulled out from under the in-memory record mid-run (callbacks bypassed —
    # the exact race end-state). The post-run reload raises RecordNotFound; the local
    # rescue must synchronously purge THIS run's fragments + sidecar so no PII of the
    # destroyed record survives with a dead fragmentable (the sidecar sweep can't see
    # it — its Fragment row is alive).
    context 'when the record is destroyed while the job is mid-run (destroy race)' do
      before do
        # A dead meeting cannot serve as a polymorphic AiUsage subject; the run still
        # meters, so stub the seam (record_embedding is best-effort anyway).
        allow(Lalabase::Llm::UsageTracking).to receive(:record_embedding)
        allow_any_instance_of(TextProcessingService).to receive(:split_text_into_fragments).and_return(['chunk one'])
      end

      it 'purges the run’s fragments and sidecar rows without raising (no orphan PII)' do
        # Bulk delete bypasses destroy callbacks/dependent — the fragments this run is
        # about to write cannot be caught by the meeting's destroy-time purge.
        Meeting.where(id: meeting.id).delete_all

        expect { described_class.new(meeting).process }.not_to raise_error

        expect(meeting.fragments).to be_empty
        expect(ContentEmbedding.where(embeddable_type: 'Fragment')).to be_empty
      end
    end
  end

  # Gespräche Slice 7b: a meeting analysis rides the SAME generic service. Its
  # create_embeddings is a METHOD (!is_private && include_in_search), so the #247
  # runtime guards (start-check + post-run reload re-check) fire automatically —
  # verified here, not rebuilt. Only a published + search-released analysis embeds.
  describe '#process with MeetingAnalysis model (Gespräche Slice 7b)' do
    let(:analysis) do
      meeting = create(:meeting, project: project, organisation: organisation, creator: user)
      create(:meeting_analysis, :published, meeting: meeting, organisation: organisation, creator: user,
                                            include_in_search: true,
                                            content: 'Besprochen: Login-Bug und die Reproschritte.')
    end

    before do
      allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
    end

    it 'creates fragments for a published+search-released analysis via the generic service' do
      expect { described_class.new(analysis).process }.to change(Fragment, :count).by_at_least(1)
    end

    it 'associates fragments with the analysis polymorphically' do
      described_class.new(analysis).process
      fragment = analysis.fragments.first
      expect(fragment.fragmentable_type).to eq('MeetingAnalysis')
      expect(fragment.fragmentable_id).to eq(analysis.id)
    end

    it 'marks embeddings_creation_flag true on success' do
      described_class.new(analysis).process
      expect(analysis.reload.read_attribute(:embeddings_creation_flag)).to be true
    end

    # Start guard (review PR #247): a job enqueued while search-released that runs only
    # AFTER the release was revoked must not resurrect the purged fragments.
    context 'when the search release was revoked after the job was enqueued' do
      it 'skips without any writes: no fragments, no provider call, flag stays nil' do
        analysis.update!(include_in_search: false)

        expect { described_class.new(analysis).process }.not_to change(Fragment, :count)
        expect(embed_provider).not_to have_received(:embed_with_usage)
        expect(analysis.reload.read_attribute(:embeddings_creation_flag)).to be_nil
      end
    end

    # Purge race (adversarial review PR #247): the job is PAST the start guard and
    # mid-loop when the opt-out purge runs. The post-run reload re-check must discard the
    # job's own writes instead of resurrecting purged PII (Entscheidung 5).
    context 'when the search release is revoked while the job is mid-run (purge race)' do
      it 'discards the just-written fragments and does not mark the flag' do
        first_call = true
        allow(embed_provider).to receive(:embed_with_usage) do
          analysis.update!(include_in_search: false) if first_call
          first_call = false
          { embedding: fake_embedding, total_tokens: 10 }
        end

        expect { described_class.new(analysis).process }.not_to(change { analysis.fragments.count })
        expect(analysis.reload.read_attribute(:embeddings_creation_flag)).to be_nil
      end
    end

    # A private analysis is NEVER embedded (Entscheidung 5) — the start guard rejects it.
    it 'skips a private analysis entirely (create_embeddings? false)' do
      analysis.update!(is_private: true)

      expect { described_class.new(analysis).process }.not_to change(Fragment, :count)
      expect(analysis.reload.read_attribute(:embeddings_creation_flag)).to be_nil
    end
  end

  describe 'private #delete_old_fragments' do
    let(:service) { described_class.new(ticket) }
    let(:new_token) { SecureRandom.uuid }

    context 'guard clauses' do
      context 'when organisation_id is nil' do
        before { allow(ticket).to receive(:organisation_id).and_return(nil) }

        it 'does not delete anything' do
          create(:fragment, fragmentable: ticket, organisation: organisation,
                            version_token: 'old-token')

          service.send(:delete_old_fragments, new_token)
          expect(ticket.fragments.count).to eq(1)
        end
      end

      context 'when new_version_token is nil' do
        it 'does not delete anything' do
          create(:fragment, fragmentable: ticket, organisation: organisation,
                            version_token: 'old-token')

          service.send(:delete_old_fragments, nil)
          expect(ticket.fragments.count).to eq(1)
        end
      end

      context 'when new_version_token is blank' do
        it 'does not delete anything' do
          create(:fragment, fragmentable: ticket, organisation: organisation,
                            version_token: 'old-token')

          service.send(:delete_old_fragments, '')
          expect(ticket.fragments.count).to eq(1)
        end
      end
    end

    context 'when there are no existing fragments' do
      it 'completes without error' do
        expect { service.send(:delete_old_fragments, new_token) }.not_to raise_error
      end
    end

    context 'when the new_version_token is not found among fragments' do
      it 'does not delete anything (early return)' do
        create(:fragment, fragmentable: ticket, organisation: organisation,
                          version_token: 'existing-token')

        service.send(:delete_old_fragments, 'non-existent-token')
        expect(ticket.fragments.count).to eq(1)
      end
    end

    context 'when only new fragments exist (no old ones)' do
      it 'does not delete the new fragments' do
        create(:fragment, fragmentable: ticket, organisation: organisation,
                          version_token: new_token)

        service.send(:delete_old_fragments, new_token)
        expect(ticket.fragments.count).to eq(1)
      end
    end

    context 'when exactly one old token exists' do
      let(:old_token) { SecureRandom.uuid }

      before do
        2.times do
          create(:fragment, fragmentable: ticket, organisation: organisation,
                            version_token: old_token)
        end
        create(:fragment, fragmentable: ticket, organisation: organisation,
                          version_token: new_token)
      end

      it 'deletes old fragments and keeps new ones' do
        expect(ticket.fragments.count).to eq(3)

        service.send(:delete_old_fragments, new_token)

        expect(ticket.fragments.reload.count).to eq(1)
        expect(ticket.fragments.first.version_token).to eq(new_token)
      end

      it 'logs the deletion' do
        expect(Rails.logger).to receive(:info).with(/Deleting 2 old fragments/)
        service.send(:delete_old_fragments, new_token)
      end
    end

    context 'when multiple old tokens exist' do
      before do
        create(:fragment, fragmentable: ticket, organisation: organisation,
                          version_token: SecureRandom.uuid)
        create(:fragment, fragmentable: ticket, organisation: organisation,
                          version_token: SecureRandom.uuid)
        create(:fragment, fragmentable: ticket, organisation: organisation,
                          version_token: new_token)
      end

      it 'deletes all old fragments regardless of how many old token groups exist' do
        expect(ticket.fragments.count).to eq(3)

        service.send(:delete_old_fragments, new_token)

        remaining = ticket.fragments.reload
        expect(remaining.count).to eq(1)
        expect(remaining.first.version_token).to eq(new_token)
      end
    end

    context 'when a database error occurs during deletion' do
      before do
        create(:fragment, fragmentable: ticket, organisation: organisation,
                          version_token: 'old-token')
        create(:fragment, fragmentable: ticket, organisation: organisation,
                          version_token: new_token)

        allow_any_instance_of(Fragment).to receive(:destroy!).and_raise(ActiveRecord::RecordNotDestroyed)
      end

      it 'logs the error and re-raises' do
        expect(Rails.logger).to receive(:error).with(/Error deleting old fragments/)
        expect { service.send(:delete_old_fragments, new_token) }.to raise_error(ActiveRecord::RecordNotDestroyed)
      end
    end
  end

  describe 'private #create_version_token' do
    let(:service) { described_class.new(ticket) }

    it 'returns a UUID string' do
      token = service.send(:create_version_token)
      expect(token).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end

    it 'returns a unique token that does not exist in fragments' do
      existing_token = SecureRandom.uuid
      create(:fragment, fragmentable: ticket, organisation: organisation,
                        version_token: existing_token)

      token = service.send(:create_version_token)
      expect(token).not_to eq(existing_token)
      expect(ticket.fragments.where(version_token: token)).not_to exist
    end
  end

  describe 'private #default_fragment_association' do
    context 'when record responds to :fragments' do
      it 'returns :fragments' do
        service = described_class.new(ticket, nil)
        expect(service.fragment_association).to eq(:fragments)
      end
    end

    context 'when record does not respond to :fragments' do
      let(:plain_record) { double('PlainRecord') }

      before do
        allow(plain_record).to receive(:respond_to?).with(:fragments).and_return(false)
      end

      it 'raises an error' do
        expect { described_class.new(plain_record, nil) }.to raise_error(RuntimeError, /No valid fragment association found/)
      end
    end
  end

  describe 'private #extract_text_fragments' do
    let(:service) { described_class.new(ticket) }

    it 'delegates to TextProcessingService' do
      text_service = instance_double(TextProcessingService)
      allow(TextProcessingService).to receive(:new).with(ticket.plain_text_version).and_return(text_service)
      allow(text_service).to receive(:split_text_into_fragments).and_return(['fragment 1', 'fragment 2'])

      result = service.send(:extract_text_fragments)
      expect(result).to eq(['fragment 1', 'fragment 2'])
    end
  end

  describe 'private #generate_embedding' do
    let(:service) { described_class.new(ticket) }

    it 'delegates to the org embedding provider (returns [embedding, tokens])' do
      result = service.send(:generate_embedding, 'some text')
      expect(result).to eq([fake_embedding, 10])
      expect(embed_provider).to have_received(:embed_with_usage).with(text: 'some text')
    end

    it 'resolves the embedding provider off the record organisation' do
      service.send(:generate_embedding, 'some text')
      expect(Lalabase::Llm::Factory).to have_received(:for_embeddings).with(ticket.organisation, space: :configured)
    end
  end

  describe 'private #mark_embeddings_as_successful' do
    it 'updates the embeddings_creation_flag to true (Note model)' do
      service = described_class.new(note)
      service.send(:mark_embeddings_as_successful)
      expect(note.reload.read_attribute(:embeddings_creation_flag)).to be true
    end

    context 'when record does not have embeddings_creation_flag' do
      let(:record_without_flag) do
        record = double('Record')
        allow(record).to receive(:class).and_return(Class.new)
        allow(record).to receive(:respond_to?).with(:embeddings_creation_flag).and_return(false)
        record
      end

      it 'raises a RuntimeError' do
        svc = described_class.new(record_without_flag)
        expect { svc.send(:mark_embeddings_as_successful) }.to raise_error(RuntimeError, /does not have an embeddings_creation_flag/)
      end
    end
  end

  describe 'private #handle_embedding_error' do
    let(:error) { StandardError.new('Something went wrong') }

    context 'with Note model (DB-backed embeddings_creation_flag)' do
      let(:service) { described_class.new(note) }

      it 'sets embeddings_creation_flag to false' do
        service.send(:handle_embedding_error, error)
        expect(note.reload.read_attribute(:embeddings_creation_flag)).to be false
      end

      it 'stores the error message' do
        service.send(:handle_embedding_error, error)
        expect(note.reload.embedding_creation_error).to eq('Something went wrong')
      end

      it 'logs the error message' do
        expect(Rails.logger).to receive(:error).with(/Something went wrong/)
        service.send(:handle_embedding_error, error)
      end
    end

    context 'when record does not respond to error attributes' do
      let(:minimal_record) do
        record = double('MinimalRecord', id: 'fake-id')
        allow(record).to receive(:class).and_return(Class.new)
        allow(record).to receive(:respond_to?).with(:embedding_creation_error).and_return(false)
        allow(record).to receive(:respond_to?).with(:embeddings_creation_flag).and_return(false)
        record
      end

      it 'does not attempt to update_columns but still logs' do
        svc = described_class.new(minimal_record)
        expect(minimal_record).not_to receive(:update_columns)
        expect(Rails.logger).to receive(:error).with(/Error creating embeddings/)
        svc.send(:handle_embedding_error, error)
      end
    end

    context 'when record responds to only one of the two error attributes' do
      let(:partial_record) do
        record = double('PartialRecord', id: 'fake-id')
        allow(record).to receive(:class).and_return(Class.new)
        allow(record).to receive(:respond_to?).with(:embedding_creation_error).and_return(true)
        allow(record).to receive(:respond_to?).with(:embeddings_creation_flag).and_return(false)
        record
      end

      it 'does not attempt to update_columns (requires both attributes)' do
        svc = described_class.new(partial_record)
        expect(partial_record).not_to receive(:update_columns)
        expect(Rails.logger).to receive(:error)
        svc.send(:handle_embedding_error, error)
      end
    end
  end

  describe 'integration: full process lifecycle' do
    before do
      allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
    end

    # CHANGED by the split: a second run over UNCHANGED text now reuses the existing set
    # instead of rotating the token. Rotation was not free — it discarded perfectly good
    # vectors and paid the provider again for the identical text. It also became actively
    # harmful once the version swap moved forward to sit with extraction: a run whose
    # embedding then failed would have thrown away the old vectors and left the record
    # with none, so a transient 429 would have cost it its semantic ranking.
    it 're-processes unchanged text without rotating or re-embedding' do
      described_class.new(note).process
      first_run_count = note.fragments.count
      first_token = note.fragments.first.version_token
      expect(first_run_count).to be >= 1
      expect(note.reload.read_attribute(:embeddings_creation_flag)).to be true

      expect { described_class.new(note.reload).process }.not_to change(ContentEmbedding, :count)
      note.fragments.reload

      expect(note.fragments.where(version_token: first_token).count).to eq(first_run_count)
      expect(note.fragments.count).to eq(first_run_count)
      expect(note.reload.read_attribute(:embeddings_creation_flag)).to be true
    end

    # The rotation itself is still the behaviour when the text actually MOVED, which is
    # the case it was always for. Without this the reuse branch above could swallow a real
    # content change and the search would keep answering with the old text.
    it 'rotates the version when the text has changed' do
      described_class.new(note).process
      first_token = note.fragments.first.version_token

      note.update!(content: 'Ein vollstaendig anderer Inhalt fuer den zweiten Lauf.')
      described_class.new(note.reload).process
      note.fragments.reload

      expect(note.fragments.where(version_token: first_token).count).to eq(0)
      expect(note.fragments.map(&:plain_text_content).join).to include('vollstaendig anderer Inhalt')
      expect(note.reload.read_attribute(:embeddings_creation_flag)).to be true
    end

    # CHANGED by the split, and this is the reuse optimisation paying for itself: with the
    # text unchanged and every fragment already carrying a vector, the second run has
    # nothing to embed and never reaches the provider at all. The outage cannot touch a
    # record that needs nothing from it.
    it 'does not even reach a failing provider when nothing needs embedding' do
      described_class.new(note).process
      first_token = note.fragments.first.version_token
      first_count = note.fragments.count

      allow(embed_provider).to receive(:embed_with_usage).and_raise(StandardError, 'API down')

      described_class.new(note.reload).process

      expect(note.fragments.reload.count).to eq(first_count)
      expect(note.fragments.where(version_token: first_token).count).to eq(first_count)
      expect(note.reload.read_attribute(:embeddings_creation_flag)).to be true
      expect(note.reload.embedding_creation_error).to be_blank
    end

    # The other half: text CHANGED and the provider is down. The new fragments are written
    # (full text keeps working), no vector is attached, and the record stays failed so a
    # catch-up comes back for it.
    it 'keeps the new fragments when the provider fails on changed text' do
      described_class.new(note).process
      first_token = note.fragments.first.version_token

      note.update!(content: 'Ein anderer Inhalt, dessen Einbettung scheitern wird.')
      allow(embed_provider).to receive(:embed_with_usage).and_raise(StandardError, 'API down')

      described_class.new(note.reload).process

      expect(note.fragments.reload).not_to be_empty
      expect(note.fragments.where(version_token: first_token).count).to eq(0)
      expect(note.reload.read_attribute(:embeddings_creation_flag)).to be false
    end
  end

  describe 'Ticket#embeddings_creation_flag reads DB value' do
    it 'returns the actual DB value (no override)' do
      ticket.update_columns(embeddings_creation_flag: false)
      expect(ticket.reload.embeddings_creation_flag).to be false
      expect(ticket.reload.read_attribute(:embeddings_creation_flag)).to be false
    end
  end

  # =========================================================================
  # Additional edge cases
  # =========================================================================

  describe '#process edge cases' do
    before do
      allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
    end

    context 'when extract_text_fragments returns empty array' do
      before do
        allow_any_instance_of(TextProcessingService).to receive(:split_text_into_fragments).and_return([])
      end

      it 'creates no fragments but still marks as successful' do
        described_class.new(ticket).process
        expect(ticket.fragments.count).to eq(0)
        expect(ticket.reload.read_attribute(:embeddings_creation_flag)).to be true
      end
    end

    context 'when generate_embedding returns nil (no AI client)' do
      before do
        allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: nil, total_tokens: 0 })
      end

      # Documented as "creates fragments with nil embedding" until PR 7, and vacuous:
      # the sidecar row is NOT NULL, so its insert fails, the m1 transaction rolls the
      # fragment back with it, and the old loop iterated an EMPTY collection. The real
      # behaviour — a fragment without a vector is not persisted at all — is asserted
      # here directly, so a regression cannot hide behind an empty each again.
      # CHANGED by the split. "A fragment without a vector is unreadable" was the premise
      # the whole design rested on, and it is wrong for the full-text reader. A vectorless
      # fragment is now a legitimate state: findable by text, absent from the semantic
      # lane, and still on the pending list so a later run gives it its vector.
      it 'persists the fragment and leaves it without a vector' do
        expect { described_class.new(ticket).process }.to change(Fragment, :count).by(1)
        fragment_ids = ticket.fragments.reload.map(&:id)
        expect(fragment_ids).not_to be_empty
        expect(ContentEmbedding.where(embeddable_type: 'Fragment', embeddable_id: fragment_ids)).to be_empty
      end
    end
  end

  describe 'private #create_version_token edge cases' do
    let(:service) { described_class.new(ticket) }

    context 'when first UUID collides with existing fragment' do
      # Retry loop intentionally executes the same exists? query multiple times.
      before { Prosopite.pause }

      it 'retries and returns a non-colliding token' do
        colliding_token = SecureRandom.uuid
        create(:fragment, fragmentable: ticket, organisation: organisation,
                          version_token: colliding_token)

        # First call returns the colliding token, second returns a fresh one
        fresh_token = SecureRandom.uuid
        allow(SecureRandom).to receive(:uuid).and_return(colliding_token, fresh_token)

        result = service.send(:create_version_token)
        expect(result).to eq(fresh_token)
      end
    end
  end

  describe 'private #delete_old_fragments edge cases' do
    let(:service) { described_class.new(ticket) }
    let(:new_token) { SecureRandom.uuid }

    before do
      allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
    end

    context 'when record.id is nil' do
      before { allow(ticket).to receive(:id).and_return(nil) }

      it 'does not delete anything' do
        create(:fragment, fragmentable: ticket, organisation: organisation,
                          version_token: 'old-token')

        service.send(:delete_old_fragments, new_token)
        expect(Fragment.count).to be >= 1
      end
    end

    context 'when fragments with nil version_token exist alongside valid ones' do
      let(:old_token) { SecureRandom.uuid }

      before do
        create(:fragment, fragmentable: ticket, organisation: organisation,
                          version_token: old_token)
        create(:fragment, fragmentable: ticket, organisation: organisation,
                          version_token: new_token)
        # Create fragment with nil version_token (bypassing validation)
        Fragment.insert!({
                           id: SecureRandom.uuid,
                           fragmentable_type: 'Ticket',
                           fragmentable_id: ticket.id,
                           organisation_id: organisation.id,
                           plain_text_content: 'orphaned fragment',
                           version_token: nil,
                           created_at: Time.current,
                           updated_at: Time.current
                         })
      end

      it 'ignores nil-token fragments and deletes only old versioned ones' do
        service.send(:delete_old_fragments, new_token)

        remaining = ticket.fragments.reload
        expect(remaining.where(version_token: new_token).count).to eq(1)
        expect(remaining.where(version_token: old_token).count).to eq(0)
      end
    end
  end

  describe 'private #mark_embeddings_as_successful edge cases' do
    let(:service) { described_class.new(ticket) }

    context 'when update returns false (validation failure)' do
      before do
        # Both keys: succeeding now also CLEARS a recorded error, so a stub pinning only
        # the flag would no longer match the call and fail for the wrong reason.
        allow(ticket).to receive(:update)
          .with(embeddings_creation_flag: true, embedding_creation_error: nil).and_return(false)
      end

      it 'does not raise an error' do
        expect { service.send(:mark_embeddings_as_successful) }.not_to raise_error
      end
    end
  end

  describe 'cleanup: multiple incomplete runs' do
    before do
      allow(embed_provider).to receive(:embed_with_usage).and_return({ embedding: fake_embedding, total_tokens: 10 })
    end

    it 'deletes all orphaned fragments from previous incomplete runs' do
      # Simulate two incomplete runs leaving fragments with different tokens
      token_a = SecureRandom.uuid
      token_b = SecureRandom.uuid
      create(:fragment, fragmentable: ticket, organisation: organisation,
                        version_token: token_a)
      create(:fragment, fragmentable: ticket, organisation: organisation,
                        version_token: token_b)

      # Third run succeeds
      described_class.new(ticket).process

      # All old fragments are cleaned up
      expect(ticket.fragments.reload.where(version_token: token_a).count).to eq(0)
      expect(ticket.fragments.reload.where(version_token: token_b).count).to eq(0)

      # Only new fragments remain
      tokens = ticket.fragments.reload.pluck(:version_token).uniq
      expect(tokens.size).to eq(1)
      expect(tokens.first).not_to eq(token_a)
      expect(tokens.first).not_to eq(token_b)
    end
  end

  # S3 KI-Kontingent metering (decision 1A, tests 11/29).
  describe 'usage metering' do
    it 'writes exactly ONE document_indexing usage row per run (test 11)' do
      expect { described_class.new(note.reload).process }
        .to change { AiUsage.where(action: 'document_indexing').count }.by(1)

      usage = AiUsage.where(action: 'document_indexing').last
      expect(usage.subject).to eq(note)
      expect(usage.credits_used).to be >= 1 # ceil, never 0
      expect(usage.metadata['fragment_count']).to be_present
    end

    context 'when the AI quota is exhausted (S3)' do
      before do
        allow(Lalabase::Llm::Factory).to receive(:for_embeddings)
          .and_raise(Lalabase::Llm::QuotaExceededError)
      end

      it 'pauses quietly WITHOUT setting embedding_creation_error (test 29)' do
        described_class.new(note.reload).process
        note.reload
        expect(note.embeddings_creation_flag).to be_falsey
        expect(note.embedding_creation_error).to be_nil
      end

      it 'writes no usage row (nothing was embedded)' do
        expect { described_class.new(note.reload).process }.not_to change(AiUsage, :count)
      end
    end

    # K2 (review 2026-07-12): a run that yields NO fragments must not meter (nothing
    # embedded) and must NOT resolve the provider — otherwise metering would be the
    # first provider resolution and could trip the quota gate AFTER the record was
    # already marked done. The record is still marked embedded (there was nothing to do).
    context 'when the record yields no fragments' do
      it 'marks it done, meters nothing, and never resolves the embedding provider' do
        service = described_class.new(note.reload)
        allow(service).to receive(:extract_text_fragments).and_return([])
        expect(Lalabase::Llm::Factory).not_to receive(:for_embeddings)

        expect { service.process }.not_to change(AiUsage, :count)
        expect(note.reload.embeddings_creation_flag).to be true
      end
    end
  end
end
