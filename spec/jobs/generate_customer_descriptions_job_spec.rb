# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GenerateCustomerDescriptionsJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:group) { create(:time_session_group, organisation: organisation, creator: user) }
  let(:generator_results) { { success: 3, failed: 0, skipped: 0, errors: [] } }
  let(:generator_instance) { instance_double(BulkCustomerDescriptionGenerator, generate_all: generator_results) }

  before do
    ActsAsTenant.current_tenant = organisation
    allow(BulkCustomerDescriptionGenerator).to receive(:new).and_return(generator_instance)
  end

  after { ActsAsTenant.current_tenant = nil }

  describe '#perform' do
    context 'with hash argument (primary interface)' do
      it 'generates descriptions for the group' do
        described_class.new.perform(time_session_group_id: group.id)

        expect(BulkCustomerDescriptionGenerator).to have_received(:new)
          .with(group, regenerate: false)
        expect(generator_instance).to have_received(:generate_all)
      end

      it 'returns the generator results' do
        result = described_class.new.perform(time_session_group_id: group.id)

        expect(result).to eq(generator_results)
      end

      it 'passes regenerate: true to the generator' do
        described_class.new.perform(time_session_group_id: group.id, regenerate: true)

        expect(BulkCustomerDescriptionGenerator).to have_received(:new)
          .with(group, regenerate: true)
      end

      it 'defaults regenerate to false' do
        described_class.new.perform(time_session_group_id: group.id)

        expect(BulkCustomerDescriptionGenerator).to have_received(:new)
          .with(group, regenerate: false)
      end

      it 'accepts optional user_id without affecting generation' do
        described_class.new.perform(time_session_group_id: group.id, user_id: user.id)

        expect(BulkCustomerDescriptionGenerator).to have_received(:new)
          .with(group, regenerate: false)
      end
    end

    context 'with positional hash argument (Solid Queue compat)' do
      it 'accepts a single positional hash' do
        described_class.new.perform({ 'time_session_group_id' => group.id })

        expect(BulkCustomerDescriptionGenerator).to have_received(:new)
          .with(group, regenerate: false)
      end

      it 'handles string keys via deep_symbolize_keys' do
        described_class.new.perform({ 'time_session_group_id' => group.id, 'regenerate' => true })

        expect(BulkCustomerDescriptionGenerator).to have_received(:new)
          .with(group, regenerate: true)
      end
    end

    context 'with raw positional group_id (legacy compat)' do
      it 'accepts a bare UUID as first argument' do
        described_class.new.perform(group.id)

        expect(BulkCustomerDescriptionGenerator).to have_received(:new)
          .with(group, regenerate: false)
      end

      it 'accepts group_id + options hash' do
        described_class.new.perform(group.id, { 'regenerate' => true })

        expect(BulkCustomerDescriptionGenerator).to have_received(:new)
          .with(group, regenerate: true)
      end
    end

    context 'logging' do
      it 'logs start at info level' do
        allow(Rails.logger).to receive(:info)

        described_class.new.perform(time_session_group_id: group.id)

        expect(Rails.logger).to have_received(:info)
          .with(/GenerateCustomerDescriptionsJob started.*group=#{group.id}/)
      end

      it 'logs completion at info level' do
        allow(Rails.logger).to receive(:info)

        described_class.new.perform(time_session_group_id: group.id)

        expect(Rails.logger).to have_received(:info)
          .with(/GenerateCustomerDescriptionsJob completed.*group=#{group.id}/)
      end

      it 'logs error at error level when generator fails' do
        allow(generator_instance).to receive(:generate_all).and_raise(RuntimeError, 'API down')
        allow(Rails.logger).to receive(:error)

        expect do
          described_class.new.perform(time_session_group_id: group.id)
        end.to raise_error(RuntimeError, 'API down')

        expect(Rails.logger).to have_received(:error)
          .with(/GenerateCustomerDescriptionsJob failed.*RuntimeError:API down/)
      end
    end
  end

  describe 'error handling' do
    context 'when TimeSessionGroup does not exist' do
      it 'raises ActiveRecord::RecordNotFound (handled by discard_on)' do
        expect do
          described_class.new.perform(time_session_group_id: SecureRandom.uuid)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context 'when user_id references a non-existent user' do
      it 'raises ActiveRecord::RecordNotFound' do
        expect do
          described_class.new.perform(time_session_group_id: group.id, user_id: SecureRandom.uuid)
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context 'when generator raises StandardError' do
      before do
        allow(generator_instance).to receive(:generate_all).and_raise(RuntimeError, 'something broke')
        allow(Rails.logger).to receive(:error)
      end

      it 're-raises the error for retry logic' do
        expect do
          described_class.new.perform(time_session_group_id: group.id)
        end.to raise_error(RuntimeError, 'something broke')
      end

      it 'logs the error before re-raising' do
        begin
          described_class.new.perform(time_session_group_id: group.id)
        rescue RuntimeError
          # expected
        end

        expect(Rails.logger).to have_received(:error)
          .with(/GenerateCustomerDescriptionsJob failed/)
      end
    end
  end

  describe 'retry configuration' do
    it 'retries Faraday::TimeoutError 3 times' do
      retries = described_class.rescue_handlers.find { |h| h.first == 'Faraday::TimeoutError' }
      expect(retries).to be_present
    end

    it 'retries Faraday::ConnectionFailed 2 times' do
      retries = described_class.rescue_handlers.find { |h| h.first == 'Faraday::ConnectionFailed' }
      expect(retries).to be_present
    end

    it 'discards ActiveRecord::RecordNotFound' do
      discards = described_class.rescue_handlers.find { |h| h.first == 'ActiveRecord::RecordNotFound' }
      expect(discards).to be_present
    end
  end

  describe 'queue configuration' do
    it 'uses the default queue' do
      expect(described_class.new.queue_name).to eq('default')
    end
  end

  describe '#normalize_arguments (via perform)' do
    context 'with missing time_session_group_id' do
      it 'raises ArgumentError for empty kwargs' do
        expect do
          described_class.new.perform(regenerate: true)
        end.to raise_error(ArgumentError, 'time_session_group_id is missing')
      end

      it 'raises ArgumentError for empty hash' do
        expect do
          described_class.new.perform({})
        end.to raise_error(ArgumentError, 'time_session_group_id is missing')
      end

      it 'raises ArgumentError when called with no arguments' do
        expect do
          described_class.new.perform
        end.to raise_error(ArgumentError, 'time_session_group_id is missing')
      end
    end

    context 'with too many positional arguments' do
      it 'raises ArgumentError' do
        expect do
          described_class.new.perform('a', 'b', 'c')
        end.to raise_error(ArgumentError, /Unable to normalize/)
      end
    end

    context 'with unsupported options type' do
      it 'raises ArgumentError when second arg is not a hash' do
        expect do
          described_class.new.perform(group.id, 'not_a_hash')
        end.to raise_error(ArgumentError, /Unsupported options type/)
      end
    end

    context 'kwargs take precedence over positional hash' do
      it 'merges both, kwargs first then positional overrides' do
        # kwargs are processed first, then positional hash merges in
        described_class.new.perform(
          { 'time_session_group_id' => group.id },
          regenerate: false
        )

        expect(BulkCustomerDescriptionGenerator).to have_received(:new)
          .with(group, regenerate: false)
      end
    end
  end

  describe 'ActiveJob enqueueing', :active_job_test_adapter do
    around do |example|
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
    ensure
      ActiveJob::Base.queue_adapter = original_adapter
    end

    it 'can be enqueued with perform_later' do
      expect do
        described_class.perform_later(time_session_group_id: group.id)
      end.to have_enqueued_job(described_class)
    end

    it 'enqueues on the default queue' do
      expect do
        described_class.perform_later(time_session_group_id: group.id)
      end.to have_enqueued_job(described_class).on_queue('default')
    end
  end
end
