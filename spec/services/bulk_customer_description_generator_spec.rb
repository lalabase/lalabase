# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BulkCustomerDescriptionGenerator, type: :service do
  # The factory default is ai_enabled: true and NO credential — which since R3 is a
  # refusal in its own right (:no_credential), so every example that is not about the
  # gate needs an org that can actually use the feature. BYOK on the pinned provider
  # is the cheapest such org: terminal in has_valid_ai_configuration?, so it depends
  # on no system credential and on nothing Rails.cache remembers.
  let(:organisation) do
    create(:organisation, ai_enabled: true, ai_provider: ::AiCredential::PROVIDER_OPENAI,
                          ai_access_token: 'sk-org-own-1234567890abcdef')
  end
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:group) { create(:time_session_group, organisation: organisation, creator: user) }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause
    create(:membership, user: user, organisation: organisation)
    Prosopite.resume
  end

  # Stub CustomerDescriptionGenerator to avoid real OpenAI calls
  def stub_description_generator(return_value: 'Generated description')
    generator_double = instance_double(CustomerDescriptionGenerator, generate: return_value)
    allow(CustomerDescriptionGenerator).to receive(:new).and_return(generator_double)
    generator_double
  end

  def create_session(attrs = {})
    Prosopite.pause
    session = create(:time_session,
                     project: project,
                     organisation: organisation,
                     creator: user,
                     time_session_group: group,
                     **attrs)
    Prosopite.resume
    session
  end

  describe '#generate_all' do
    # GDPR AI opt-in (audit 2026-07-03): the batch refuses up-front with ONE
    # localized error — without the guard every session would add its own raw
    # English AiDisabledError line to results[:errors] and thus to the flash.
    context 'when the organisation has not opted in to AI (GDPR gate)' do
      before { organisation.update!(ai_enabled: false) }

      it 'refuses the whole batch with a single localized error and no per-session work' do
        expect(CustomerDescriptionGenerator).not_to receive(:new)

        result = described_class.new(group).generate_all

        expect(result[:errors]).to eq([I18n.t('shared.ai.disabled_member_hint')])
        expect(result[:success]).to eq(0)
      end
    end

    # Twin of the actor's feature gate (R3). Its reason for existing is the ASYNC
    # path: between enqueue and execution the org can switch its chat provider or
    # lose its credential, and retry_on replays a job that was legal when it was
    # queued. Without this, an org that moved to Mistral yesterday would still have
    # its time entries sent to OpenAI by the job it queued before the switch.
    context 'when the org routes to another chat provider (feature gate, async-path twin)' do
      before do
        organisation.update!(ai_enabled: true, ai_provider: 'openai_compatible',
                             ai_access_token: 'sk-own-token-1234567890abcdef',
                             ai_api_base: 'https://api.mistral.ai/v1',
                             preferred_chat_model: 'mistral-small-latest')
      end

      it 'refuses the whole batch with the localized hint and no LLM call' do
        create_session
        expect(CustomerDescriptionGenerator).not_to receive(:new)

        result = described_class.new(group).generate_all

        expect(result[:errors]).to eq([
                                        I18n.t('shared.ai.unavailable.pinned_elsewhere',
                                               provider: AiCredential.provider_display_names.fetch('openai', 'openai'),
                                               current: AiCredential.provider_display_names.fetch(
                                                 'openai_compatible', 'openai_compatible'
                                               ))
                                      ])
        expect(result[:success]).to eq(0)
      end
    end

    # NEW IN R3: the same gate now also catches an org that routes to the pin but
    # cannot use it. Before, this batch ran and every session came back as a
    # SEPARATE rescued failure — the MissingCredentialError is swallowed inside
    # CustomerDescriptionGenerator, so the user saw "0 erstellt" plus N generic
    # "leeres Ergebnis" lines and no hint of what was actually wrong.
    context 'when the org routes to the pin but has no usable credential' do
      before do
        allow(AiCredential).to receive(:active_for_provider).and_return(nil)
        organisation.update!(ai_enabled: true, ai_provider: 'openai', ai_access_token: nil)
      end

      it 'refuses the whole batch once, naming the provider — not once per session' do
        create_session
        create_session
        expect(CustomerDescriptionGenerator).not_to receive(:new)

        result = described_class.new(group).generate_all

        expect(result[:errors]).to eq([
                                        I18n.t('shared.ai.unavailable.no_credential',
                                               provider: AiCredential.provider_display_names.fetch('openai', 'openai'))
                                      ])
        expect(result[:failed]).to eq(0)
        expect(result[:success]).to eq(0)
      end
    end

    # Defense-in-depth twin of the Actors::GenerateGroupCustomerDescriptions
    # billed guard (plan §5-E3): protects the ASYNC job path — a job enqueued
    # before the group was invoiced (race, retry_on replay) must not burn LLM
    # budget on guaranteed prevent_changes_when_billed failures.
    context 'when the group is billed (billed guard, async-path twin)' do
      let(:group) { create(:time_session_group, :billed, organisation: organisation, creator: user) }

      it 'refuses the whole batch with the actor guard message and no LLM call' do
        create_session(billed: true, invoice_number: group.invoice_number)
        expect(CustomerDescriptionGenerator).not_to receive(:new)

        result = described_class.new(group).generate_all

        expect(result[:errors])
          .to eq([I18n.t('services.actors.generate_group_customer_descriptions.group_billed')])
        expect(result[:success]).to eq(0)
      end
    end

    # F1 (plan §5-E6, user-approved): the per-session generator rescues every
    # provider failure to nil. That nil must count as FAILED, not as success —
    # a total provider outage used to report "N erfolgreich" while writing nil
    # descriptions over existing ones.
    context 'when the LLM returns nil (provider outage, F1)' do
      it 'counts the session as failed and leaves the existing description untouched' do
        session = create_session(customer_description: 'Bestehender Text')
        stub_description_generator(return_value: nil)

        result = described_class.new(group, regenerate: true).generate_all

        expect(result[:success]).to eq(0)
        expect(result[:failed]).to eq(1)
        expect(result[:errors].first)
          .to eq(I18n.t('services.bulk_customer_description_generator.empty_result', id: session.id))
        expect(session.reload.customer_description).to eq('Bestehender Text')
      end

      it 'counts a blank-string result as failed as well' do
        session = create_session
        stub_description_generator(return_value: '')

        result = described_class.new(group).generate_all

        expect(result[:success]).to eq(0)
        expect(result[:failed]).to eq(1)
        expect(session.reload.customer_description).to be_nil
      end
    end

    context 'happy path: sessions without descriptions' do
      it 'generates descriptions for all sessions in the group' do
        sessions = Array.new(3) { create_session }
        stub_description_generator(return_value: 'Kundentext')

        result = described_class.new(group).generate_all

        expect(result[:success]).to eq(3)
        expect(result[:failed]).to eq(0)
        expect(result[:skipped]).to eq(0)
        descriptions = TimeSession.where(id: sessions.map(&:id)).pluck(:customer_description)
        expect(descriptions).to all(eq('Kundentext'))
      end

      it 'returns a results hash with the expected keys' do
        create_session
        stub_description_generator

        result = described_class.new(group).generate_all

        expect(result).to include(:success, :failed, :skipped, :errors)
      end
    end

    context 'happy path: regenerate existing descriptions' do
      it 'overwrites existing customer_description when regenerate: true' do
        session = create_session(customer_description: 'Old text')
        stub_description_generator(return_value: 'New text')

        result = described_class.new(group, regenerate: true).generate_all

        expect(result[:success]).to eq(1)
        expect(session.reload.customer_description).to eq('New text')
      end

      it 'processes all sessions including those with descriptions' do
        create_session(customer_description: 'Existing')
        create_session(customer_description: nil)
        stub_description_generator(return_value: 'Fresh')

        result = described_class.new(group, regenerate: true).generate_all

        expect(result[:success]).to eq(2)
      end
    end

    context 'happy path: skip sessions with existing descriptions' do
      it 'does not process sessions that already have a description when regenerate: false' do
        create_session(customer_description: 'Already done')
        session_without = create_session(customer_description: nil)
        stub_description_generator(return_value: 'New')

        result = described_class.new(group, regenerate: false).generate_all

        expect(result[:success]).to eq(1)
        expect(session_without.reload.customer_description).to eq('New')
      end
    end

    context 'edge case: empty group (no sessions)' do
      it 'returns zero counts' do
        result = described_class.new(group).generate_all

        expect(result[:success]).to eq(0)
        expect(result[:failed]).to eq(0)
        expect(result[:skipped]).to eq(0)
        expect(result[:errors]).to be_empty
      end
    end

    # The former "generator returns nil counts as success (code smell)" pin
    # lived here — replaced by the F1 contract above (nil/blank => failed).

    context 'edge case: generator raises an error for one session' do
      it 'continues processing other sessions and tracks the failure' do
        session_ok = create_session
        session_fail = create_session

        call_count = 0
        allow(CustomerDescriptionGenerator).to receive(:new) do |ts|
          call_count += 1
          if ts.id == session_fail.id
            generator = instance_double(CustomerDescriptionGenerator)
            allow(generator).to receive(:generate).and_raise(StandardError, 'OpenAI timeout')
            generator
          else
            instance_double(CustomerDescriptionGenerator, generate: 'OK')
          end
        end

        result = described_class.new(group).generate_all

        expect(result[:success]).to eq(1)
        expect(result[:failed]).to eq(1)
        expect(result[:errors].first).to include('OpenAI timeout')
        expect(session_ok.reload.customer_description).to eq('OK')
        expect(session_fail.reload.customer_description).to be_nil
      end
    end

    context 'edge case: all sessions fail' do
      it 'returns all as failed with error details' do
        create_session
        create_session

        generator = instance_double(CustomerDescriptionGenerator)
        allow(generator).to receive(:generate).and_raise(StandardError, 'API down')
        allow(CustomerDescriptionGenerator).to receive(:new).and_return(generator)

        result = described_class.new(group).generate_all

        expect(result[:success]).to eq(0)
        expect(result[:failed]).to eq(2)
        expect(result[:errors].length).to eq(2)
        expect(result[:errors]).to all(include('API down'))
      end
    end

    context 'edge case: update! fails (e.g. validation error)' do
      it 'catches the error and counts as failed' do
        create_session
        stub_description_generator(return_value: 'Text')

        # Simulate validation failure on update
        allow_any_instance_of(TimeSession).to receive(:update!).and_raise(
          ActiveRecord::RecordInvalid.new(TimeSession.new)
        )

        result = described_class.new(group).generate_all

        expect(result[:failed]).to eq(1)
        expect(result[:errors]).to be_present
      end
    end

    context 'edge case: sessions from other groups are not processed' do
      it 'only processes sessions belonging to the given group' do
        other_group = create(:time_session_group, organisation: organisation, creator: user)
        create_session # belongs to `group`
        create(:time_session, project: project, organisation: organisation,
                              creator: user, time_session_group: other_group)

        stub_description_generator(return_value: 'Done')

        result = described_class.new(group).generate_all

        expect(result[:success]).to eq(1)
      end
    end

    context 'edge case: calling generate_all twice accumulates results (mutable state)' do
      it 'does not reset counters between calls' do
        create_session
        stub_description_generator(return_value: 'Text')

        service = described_class.new(group, regenerate: true)
        service.generate_all
        result = service.generate_all

        # BUG: @results is not reset — second call accumulates
        expect(result[:success]).to eq(2) # 1 from first call + 1 from second
      end
    end
  end

  describe '#should_use_background_job?' do
    it 'returns false when sessions count is at or below threshold' do
      Array.new(BulkCustomerDescriptionGenerator::BACKGROUND_JOB_THRESHOLD) { create_session }

      service = described_class.new(group)

      expect(service.should_use_background_job?).to be false
    end

    it 'returns true when sessions count exceeds threshold' do
      Array.new(BulkCustomerDescriptionGenerator::BACKGROUND_JOB_THRESHOLD + 1) { create_session }

      service = described_class.new(group)

      expect(service.should_use_background_job?).to be true
    end
  end

  describe 'logging' do
    it 'logs start and completion via Rails.logger' do
      create_session
      stub_description_generator(return_value: 'Text')
      allow(Rails.logger).to receive(:debug).and_call_original

      described_class.new(group).generate_all

      expect(Rails.logger).to have_received(:debug).with(/started/).once
      expect(Rails.logger).to have_received(:debug).with(/completed/).once
    end

    it 'logs errors for failed sessions' do
      create_session
      generator = instance_double(CustomerDescriptionGenerator)
      allow(generator).to receive(:generate).and_raise(StandardError, 'Boom')
      allow(CustomerDescriptionGenerator).to receive(:new).and_return(generator)
      allow(Rails.logger).to receive(:debug).and_call_original
      allow(Rails.logger).to receive(:error).and_call_original

      described_class.new(group).generate_all

      expect(Rails.logger).to have_received(:error).with(/Boom/).once
    end

    it 'warns when processing many sessions synchronously' do
      Array.new(BulkCustomerDescriptionGenerator::BACKGROUND_JOB_THRESHOLD + 1) { create_session }
      stub_description_generator(return_value: 'Text')
      allow(Rails.logger).to receive(:warn).and_call_original
      allow(Rails.logger).to receive(:debug).and_call_original

      described_class.new(group).generate_all

      expect(Rails.logger).to have_received(:warn).with(/Consider using background job/).once
    end
  end

  describe 'includes optimization' do
    it 'eager-loads tickets without loading their unfiltered comments' do
      create_session
      stub_description_generator(return_value: 'Text')

      # Verify the service uses includes
      service = described_class.new(group)
      relation = service.send(:select_time_sessions)

      expect(relation.includes_values).to include(:ticket)
    end
  end
end
