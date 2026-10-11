# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmbeddingProcessingJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation, creator: user) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def perform_job(**overrides)
    defaults = { record_class: Ticket, record_id: ticket.id, fragment_association: :fragments }
    described_class.new.perform(**defaults.merge(overrides))
  end

  describe 'queue configuration' do
    it 'uses the default queue' do
      expect(described_class.new.queue_name).to eq('default')
    end
  end

  describe 'discard_on configuration' do
    it 'has a discard_on handler for ActiveRecord::RecordNotFound' do
      handlers = described_class.rescue_handlers.select { |h| h.first == 'ActiveRecord::RecordNotFound' }
      expect(handlers).to be_present
    end
  end

  # The concurrency limit arrived with the fragment/embedding split: reuse means two runs
  # share fragment ids, so both aim at the same slot in idx_content_embeddings_unique_space.
  describe 'concurrency limit' do
    # ⚠️ This computes the key the way Solid Queue does (instance_exec(*arguments)), which
    # is the only thing that proves the lambda actually works. ActiveJob passes keyword
    # arguments as ONE ruby2_keywords-flagged hash, so a lambda written with two positional
    # parameters would raise ArgumentError at ENQUEUE time, on every save, in production —
    # and nothing else in this suite ever computes the key.
    it 'derives one key per record from the job arguments' do
      job = described_class.new(record_class: Note, record_id: 'abc-123', fragment_association: :fragments)

      expect(job.concurrency_key).to include('embed-Note-abc-123')
    end

    it 'gives two records of the same class different keys' do
      one = described_class.new(record_class: Note, record_id: 'aaa', fragment_association: :fragments)
      two = described_class.new(record_class: Note, record_id: 'bbb', fragment_association: :fragments)

      expect(one.concurrency_key).not_to eq(two.concurrency_key)
    end

    # ⚠️ A one-word pin, and it earns its place: :discard was the first draft and it is
    # SILENT. Solid Queue destroys a conflicting job in after_create, so a save landing
    # during a running job would vanish before a worker sees it; the running job then marks
    # embeddings_creation_flag = true over the OLDER text, and Embeddings::PendingEmbeddings
    # selects on that flag, so nothing ever comes back for the newer one. Stale search
    # results with no error anywhere. See the comment on the job for why blocking is free.
    it 'blocks a conflicting run rather than discarding it' do
      expect(described_class.concurrency_on_conflict).to eq(:block)
    end
  end

  describe '#perform' do
    context 'happy path' do
      it 'finds the record and delegates to EmbeddingProcessingService' do
        service = instance_double(EmbeddingProcessingService, process: nil)
        allow(EmbeddingProcessingService).to receive(:new)
          .with(ticket, :fragments)
          .and_return(service)

        perform_job

        expect(service).to have_received(:process)
      end

      it 'passes custom fragment_association to the service' do
        service = instance_double(EmbeddingProcessingService, process: nil)
        allow(EmbeddingProcessingService).to receive(:new)
          .with(ticket, :custom_fragments)
          .and_return(service)

        perform_job(fragment_association: :custom_fragments)

        expect(service).to have_received(:process)
      end

      it 'defaults fragment_association to :fragments when not provided' do
        service = instance_double(EmbeddingProcessingService, process: nil)
        allow(EmbeddingProcessingService).to receive(:new)
          .with(ticket, :fragments)
          .and_return(service)

        described_class.new.perform(record_class: Ticket, record_id: ticket.id)

        expect(service).to have_received(:process)
      end
    end

    context 'tenant context' do
      it 'sets ActsAsTenant to the record organisation during processing' do
        # Force ticket creation while tenant is set
        record_id = ticket.id

        tenant_during_process = nil
        service = instance_double(EmbeddingProcessingService)
        allow(EmbeddingProcessingService).to receive(:new).and_return(service)
        allow(service).to receive(:process) { tenant_during_process = ActsAsTenant.current_tenant }

        # Clear tenant to simulate background job context
        ActsAsTenant.current_tenant = nil
        described_class.new.perform(record_class: Ticket, record_id: record_id)

        expect(tenant_during_process).to eq(organisation)
      end

      it 'finds the record without requiring a tenant (without_tenant)' do
        record_id = ticket.id

        service = instance_double(EmbeddingProcessingService, process: nil)
        allow(EmbeddingProcessingService).to receive(:new).and_return(service)

        # Without the without_tenant wrapper, this would raise NoTenantSet
        ActsAsTenant.current_tenant = nil

        expect do
          described_class.new.perform(record_class: Ticket, record_id: record_id)
        end.not_to raise_error
      end

      it 'restores previous tenant context after processing' do
        service = instance_double(EmbeddingProcessingService, process: nil)
        allow(EmbeddingProcessingService).to receive(:new).and_return(service)

        perform_job

        expect(ActsAsTenant.current_tenant).to eq(organisation)
      end

      it 'restores tenant context even when the service raises' do
        record_id = ticket.id

        allow(EmbeddingProcessingService).to receive(:new)
          .and_raise(StandardError, 'service failure')

        ActsAsTenant.current_tenant = nil

        expect do
          described_class.new.perform(record_class: Ticket, record_id: record_id)
        end.to raise_error(StandardError, 'service failure')

        expect(ActsAsTenant.current_tenant).to be_nil
      end
    end

    context 'when record does not exist' do
      let(:missing_id) { SecureRandom.uuid }

      it 'raises ActiveRecord::RecordNotFound (handled by discard_on at framework level)' do
        expect do
          perform_job(record_id: missing_id)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'does not instantiate EmbeddingProcessingService' do
        expect(EmbeddingProcessingService).not_to receive(:new)

        begin
          perform_job(record_id: missing_id)
        rescue ActiveRecord::RecordNotFound
          # expected — discard_on handles this at the ActiveJob framework level
        end
      end
    end

    context 'when record is deleted between enqueue and execution' do
      it 'raises RecordNotFound for the deleted record' do
        record_id = ticket.id
        ticket.destroy!

        expect do
          perform_job(record_id: record_id)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context 'when EmbeddingProcessingService raises' do
      it 'lets the error propagate for framework retry/discard handling' do
        allow(EmbeddingProcessingService).to receive(:new)
          .and_raise(RuntimeError, 'unexpected service error')

        expect { perform_job }.to raise_error(RuntimeError, 'unexpected service error')
      end
    end

    context 'with different record types' do
      let(:note) do
        create(:note, project: project, organisation: organisation, creator: user,
                      plain_text_version: 'Test content for note embedding.')
      end

      it 'works with Note records' do
        service = instance_double(EmbeddingProcessingService, process: nil)
        allow(EmbeddingProcessingService).to receive(:new)
          .with(note, :fragments)
          .and_return(service)

        described_class.new.perform(record_class: Note, record_id: note.id)

        expect(service).to have_received(:process)
      end

      it 'sets tenant from the Note organisation' do
        record_id = note.id

        tenant_during_process = nil
        service = instance_double(EmbeddingProcessingService)
        allow(EmbeddingProcessingService).to receive(:new).and_return(service)
        allow(service).to receive(:process) { tenant_during_process = ActsAsTenant.current_tenant }

        ActsAsTenant.current_tenant = nil
        described_class.new.perform(record_class: Note, record_id: record_id)

        expect(tenant_during_process).to eq(organisation)
      end
    end
  end

  describe 'ActiveJob enqueueing' do
    around do |example|
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
    ensure
      ActiveJob::Base.queue_adapter = original_adapter
    end

    before do
      # Undo global stub from spec/support/jobs_helper.rb so perform_later actually enqueues
      RSpec::Mocks.space.proxy_for(described_class).reset
    end

    it 'can be enqueued with perform_later' do
      expect do
        described_class.perform_later(record_class: Ticket, record_id: ticket.id)
      end.to have_enqueued_job(described_class)
    end

    it 'enqueues in the default queue' do
      expect do
        described_class.perform_later(record_class: Ticket, record_id: ticket.id)
      end.to have_enqueued_job(described_class).on_queue('default')
    end

    it 'serializes all keyword arguments correctly' do
      expect do
        described_class.perform_later(
          record_class: Ticket,
          record_id: ticket.id,
          fragment_association: :custom_fragments
        )
      end.to have_enqueued_job(described_class).with(
        record_class: Ticket,
        record_id: ticket.id,
        fragment_association: :custom_fragments
      )
    end
  end

  describe 'discard_on behavior (via perform_now)' do
    it 'discards the job when record is not found' do
      expect do
        described_class.perform_now(record_class: Ticket, record_id: SecureRandom.uuid)
      end.not_to raise_error
    end

    it 'logs a warning when discarding' do
      expect(Rails.logger).to receive(:warn).with(/EmbeddingProcessingJob discarded/)

      described_class.perform_now(record_class: Ticket, record_id: SecureRandom.uuid)
    end

    it 'does not call EmbeddingProcessingService when discarding' do
      expect(EmbeddingProcessingService).not_to receive(:new)

      described_class.perform_now(record_class: Ticket, record_id: SecureRandom.uuid)
    end
  end
end
