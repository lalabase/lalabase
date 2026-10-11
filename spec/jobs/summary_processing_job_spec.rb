# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SummaryProcessingJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:document) { create(:document, project: project, organisation: organisation, creator: user) }
  let(:document_version) do
    create(:document_version, document: document, organisation: organisation,
                              create_summary: true, plain_text_version: 'Some document text')
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def perform_job(record_class: DocumentVersion, record_id: document_version.id)
    described_class.new.perform(record_class: record_class, record_id: record_id)
  end

  def stub_summary_service(result: nil)
    service = instance_double(SummaryProcessingService, process: result)
    allow(SummaryProcessingService).to receive(:new).and_return(service)
    service
  end

  describe 'queue configuration' do
    it 'uses the default queue' do
      expect(described_class.new.queue_name).to eq('default')
    end

    it 'defines a LOG_TAG constant' do
      expect(described_class::LOG_TAG).to eq('SummaryProcessingJob')
    end
  end

  describe '#perform' do
    context 'happy path' do
      it 'finds the record and delegates to SummaryProcessingService' do
        service = stub_summary_service

        perform_job

        expect(SummaryProcessingService).to have_received(:new).with(document_version)
        expect(service).to have_received(:process)
      end
    end

    context 'when record is not found' do
      let(:non_existent_id) { SecureRandom.uuid }

      it 'logs a warning and does not raise' do
        expect(Rails.logger).to receive(:warn).with(
          /#{described_class::LOG_TAG}: DocumentVersion with ID #{non_existent_id} not found/
        )

        expect { perform_job(record_id: non_existent_id) }.not_to raise_error
      end

      it 'does not call SummaryProcessingService' do
        allow(Rails.logger).to receive(:warn)

        expect(SummaryProcessingService).not_to receive(:new)

        perform_job(record_id: non_existent_id)
      end
    end

    context 'when SummaryProcessingService.new raises StandardError' do
      it 'logs the error and re-raises for retry' do
        allow(SummaryProcessingService).to receive(:new)
          .and_raise(StandardError, 'API timeout')

        expect(Rails.logger).to receive(:error).with(
          /#{described_class::LOG_TAG}: Error processing DocumentVersion with ID #{document_version.id} - API timeout/
        )

        expect { perform_job }.to raise_error(StandardError, 'API timeout')
      end
    end

    context 'when service#process raises RuntimeError' do
      it 'logs and re-raises' do
        service = instance_double(SummaryProcessingService)
        allow(SummaryProcessingService).to receive(:new).and_return(service)
        allow(service).to receive(:process).and_raise(RuntimeError, 'OpenAI rate limit')

        expect(Rails.logger).to receive(:error).with(/OpenAI rate limit/)

        expect { perform_job }.to raise_error(RuntimeError, 'OpenAI rate limit')
      end
    end

    context 'when service#process raises ActiveRecord::RecordInvalid' do
      it 're-raises to allow retry (does not swallow)' do
        service = instance_double(SummaryProcessingService)
        allow(SummaryProcessingService).to receive(:new).and_return(service)
        allow(service).to receive(:process)
          .and_raise(ActiveRecord::RecordInvalid.new(document_version))

        expect { perform_job }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe '#perform tenant context (regression, Codex finding 2026-07-11)' do
    # Solid Queue deserializes and runs jobs with NO ambient tenant. The record is
    # created while the tenant is current (global before), then the tenant is
    # cleared so #perform must re-establish it itself. Before the fix,
    # record_class.find raised ActsAsTenant::Errors::NoTenantSet (require_tenant =
    # true) for every tenanted summary — the whole feature was broken outside a
    # request. Setting the tenant in a before (NOT around) so the record exists
    # before it is cleared.
    before do
      document_version # force creation while the tenant is still current
      ActsAsTenant.current_tenant = nil
    end

    it 'loads the tenanted record and runs the service inside its organisation' do
      tenant_seen = nil
      service = instance_double(SummaryProcessingService)
      allow(SummaryProcessingService).to receive(:new).and_return(service)
      allow(service).to receive(:process) { tenant_seen = ActsAsTenant.current_tenant }

      expect { perform_job }.not_to raise_error
      expect(SummaryProcessingService).to have_received(:new).with(document_version)
      expect(tenant_seen).to eq(organisation)
    end
  end

  describe 'deserialization' do
    it 'has a discard handler for ActiveJob::DeserializationError' do
      handlers = described_class.rescue_handlers.select { |h| h.first == 'ActiveJob::DeserializationError' }
      expect(handlers).to be_present
    end

    it 'invokes discard block without raising' do
      # DeserializationError reads $! in initialize, so must be created inside rescue
      error = begin
        raise ActiveRecord::RecordNotFound, 'DocumentVersion not found'
      rescue ActiveRecord::RecordNotFound
        ActiveJob::DeserializationError.new
      end

      job = described_class.new

      described_class.rescue_handlers.each do |handler_class, _options, block|
        next unless handler_class == 'ActiveJob::DeserializationError'

        expect { block&.call(job, error) }.not_to raise_error
      end
    end
  end

  describe 'interface contract' do
    it 'does not accept fragment_association parameter' do
      stub_summary_service

      expect do
        described_class.new.perform(
          record_class: DocumentVersion,
          record_id: document_version.id,
          fragment_association: :fragments
        )
      end.to raise_error(ArgumentError)
    end

    it 'requires record_class keyword argument' do
      expect do
        described_class.new.perform(record_id: document_version.id)
      end.to raise_error(ArgumentError)
    end

    it 'requires record_id keyword argument' do
      expect do
        described_class.new.perform(record_class: DocumentVersion)
      end.to raise_error(ArgumentError)
    end
  end
end
