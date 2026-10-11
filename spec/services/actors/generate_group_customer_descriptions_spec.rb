# frozen_string_literal: true

# spec/services/actors/generate_group_customer_descriptions_spec.rb
#
# What: unit spec for the GenerateGroupCustomerDescriptions Tier-2 actor.
# Why: pins the billed refuse BEFORE any LLM call or enqueue (plan §9.8-5), the
#   sync/async threshold boundary including the regenerate semantics (plan §9.4
#   threshold pin), the after-commit job args (bit-identical hash form), and the
#   pass-through of the sync counters via #outcome.
#
# Job-enqueue assertions live HERE and not in the request specs (plan §9.8-7):
# after_all_transactions_commit fires synchronously under transactional
# fixtures, which is reliable on the actor level only.

require 'rails_helper'

RSpec.describe Actors::GenerateGroupCustomerDescriptions, type: :service do
  include ActiveJob::TestHelper

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

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  def sessions_without_description(count, target: group)
    create_list(:time_session, count,
                organisation: organisation, project: project, creator: user,
                time_session_group: target, customer_description: nil)
  end

  def build_actor(regenerate: false, target: group)
    described_class.new(group: target, regenerate: regenerate, current_user: user)
  end

  # LLM seam stub: no real CustomerDescriptionGenerator (and thus no provider
  # call) ever runs in this spec.
  def stub_llm_seam(description = 'Beschreibung')
    allow(CustomerDescriptionGenerator).to receive(:new)
      .and_return(instance_double(CustomerDescriptionGenerator, generate: description))
  end

  describe 'threshold pin (plan §9.4)' do
    it 'pins the sync/async boundary constant to 10' do
      expect(BulkCustomerDescriptionGenerator::BACKGROUND_JOB_THRESHOLD).to eq(10)
    end
  end

  describe 'sync/async fork (boundary n / n+1)' do
    it 'runs synchronously AT the threshold (10 relevant sessions) without a job' do
      sessions_without_description(10)
      stub_llm_seam

      actor = build_actor
      result = nil
      expect { result = actor.call }.not_to have_enqueued_job(GenerateCustomerDescriptionsJob)

      expect(result).to be_success
      expect(actor.outcome.mode).to eq(:synchronous)
      expect(actor.outcome.results[:success]).to eq(10)
    end

    it 'enqueues the background job ABOVE the threshold (11) with the existing hash args' do
      sessions_without_description(11)
      allow(CustomerDescriptionGenerator).to receive(:new)

      actor = build_actor
      result = nil
      expect { result = actor.call }.to have_enqueued_job(GenerateCustomerDescriptionsJob)
        .with(hash_including(time_session_group_id: group.id, regenerate: false, user_id: user.id))

      expect(result).to be_success
      expect(actor.outcome.mode).to eq(:enqueued)
      expect(CustomerDescriptionGenerator).not_to have_received(:new)
    end

    context 'with 11 sessions, 2 of them already described (regenerate semantics of the threshold)' do
      before do
        sessions_without_description(9)
        create_list(:time_session, 2,
                    organisation: organisation, project: project, creator: user,
                    time_session_group: group, customer_description: 'Vorhanden')
      end

      it 'counts only sessions without a description when regenerate is false (9 relevant => sync)' do
        stub_llm_seam

        actor = build_actor(regenerate: false)
        expect { actor.call }.not_to have_enqueued_job(GenerateCustomerDescriptionsJob)

        expect(actor.outcome.mode).to eq(:synchronous)
      end

      it 'counts ALL sessions when regenerate is true (11 relevant => async)' do
        actor = build_actor(regenerate: true)
        expect { actor.call }.to have_enqueued_job(GenerateCustomerDescriptionsJob)
          .with(hash_including(regenerate: true))

        expect(actor.outcome.mode).to eq(:enqueued)
      end
    end
  end

  describe 'billed guard (plan §9.8-5)' do
    it 'refuses a billed group before any LLM call or enqueue' do
      billed_group = create(:time_session_group, :billed, organisation: organisation, creator: user)
      create(:time_session,
             organisation: organisation, project: project, creator: user,
             time_session_group: billed_group, billed: true,
             invoice_number: billed_group.invoice_number, customer_description: nil)
      allow(CustomerDescriptionGenerator).to receive(:new)

      actor = build_actor(target: billed_group)
      result = nil
      expect { result = actor.call }.not_to have_enqueued_job(GenerateCustomerDescriptionsJob)

      expect(result).not_to be_success
      expect(result.code).to eq(:group_billed)
      expect(result.errors.first)
        .to eq(I18n.t('services.actors.generate_group_customer_descriptions.group_billed'))
      expect(CustomerDescriptionGenerator).not_to have_received(:new)
    end

    # Mutation-killer for the .reload in guard_group_not_billed! (plan §9.8-1):
    # the TOCTOU race defense only shows when the actor holds a STALE unbilled
    # instance while the DB row was invoiced concurrently. Without the .reload
    # the guard reads the stale false and the actor proceeds — the bulk
    # generator's defense-in-depth twin reads the SAME stale instance and does
    # not catch it either — so this test pins the fresh DB read itself.
    it 'refuses a group invoiced concurrently behind a stale in-memory instance (reload race defense)' do
      sessions_without_description(1)
      allow(CustomerDescriptionGenerator).to receive(:new)

      # Flip the DB row BEHIND the actor's instance: update_columns on a
      # separately loaded copy keeps `group` unbilled in-memory.
      TimeSessionGroup.find(group.id)
                      .update_columns(billed: true, invoice_number: 'INV-RACE', billed_at: Time.current)
      expect(group).not_to be_billed # race precondition: instance is stale

      actor = build_actor
      result = nil
      expect { result = actor.call }.not_to have_enqueued_job(GenerateCustomerDescriptionsJob)

      expect(result).not_to be_success
      expect(result.code).to eq(:group_billed)
      expect(CustomerDescriptionGenerator).not_to have_received(:new)
    end
  end

  # R3 (doc/ai_feature_registry_plan.md): the actor asks the FEATURE question —
  # ai_available_for?(:customer_description) — where S4 asked the provider question
  # alone. :customer_description is pinned to OpenAI and cannot follow the org's chat
  # provider (gpt-5-nano is a reasoning model whose reasoning_effort travels via
  # provider_options), so orgs routing elsewhere are switched OFF and told why
  # instead of having their time entries silently sent to OpenAI. Since R3 the same
  # gate also refuses an org that routes to the pin but cannot use it.
  describe 'feature gate (R3)' do
    let(:pinned) { ::AiCredential::PROVIDER_OPENAI }

    def route_org_to(provider)
      organisation.update!(ai_enabled: true, ai_provider: provider,
                           ai_access_token: 'sk-own-token-1234567890abcdef',
                           ai_api_base: 'https://api.mistral.ai/v1',
                           preferred_chat_model: 'mistral-small-latest')
    end

    it 'refuses an org routing elsewhere before any LLM call or enqueue' do
      sessions_without_description(1)
      stub_llm_seam
      route_org_to('openai_compatible')

      actor = build_actor
      result = nil
      expect { result = actor.call }.not_to have_enqueued_job(GenerateCustomerDescriptionsJob)

      expect(result).not_to be_success
      expect(result.code).to eq(:feature_unavailable)
      expect(CustomerDescriptionGenerator).not_to have_received(:new)
    end

    # The example above uses ONE session, which is below the async threshold — so it
    # would pass even with the guard at the very end of #call, because nothing would
    # have been enqueued anyway. Above the threshold the two orders differ: an actor
    # that refuses late has already run enqueue_after_commit (no open transaction ⇒
    # the block fires immediately), leaving a job queued for a group whose feature is
    # switched off. The async twin then refuses it into the LOG, where no user ever
    # sees it — which is the "N silent failures" shape R3 exists to remove.
    it 'refuses an ABOVE-threshold group without queuing the background job' do
      sessions_without_description(11)
      allow(CustomerDescriptionGenerator).to receive(:new)
      route_org_to('openai_compatible')

      actor = build_actor
      result = nil
      expect { result = actor.call }.not_to have_enqueued_job(GenerateCustomerDescriptionsJob)

      expect(result.code).to eq(:feature_unavailable)
      expect(actor.outcome).to be_nil
    end

    # The opt-in is a refusal in its own right since R3, and the FIRST one asked —
    # an org without the GDPR opt-in has one problem, and naming a credential or a
    # provider instead sends its admin to the wrong settings page. Before R3 this
    # org passed the actor guard entirely: the batch started, the async twin's own
    # ai_enabled? check refused it, and the controller turned the resulting 0/0/0
    # counters into the generic "Keine Beschreibungen erstellt" — the explanation
    # was in results[:errors] and build_flash_message drops that array.
    it 'refuses an org without the AI opt-in, with the canonical opt-in copy' do
      sessions_without_description(1)
      allow(CustomerDescriptionGenerator).to receive(:new)
      organisation.update!(ai_enabled: false)

      result = build_actor.call

      expect(result).not_to be_success
      expect(result.code).to eq(:feature_unavailable)
      expect(result.errors.first).to eq(I18n.t('shared.ai.disabled_member_hint'))
      expect(CustomerDescriptionGenerator).not_to have_received(:new)
    end

    # The message must name BOTH providers — "needs OpenAI" alone leaves the admin
    # guessing what the org is on, and the flash is the only place this is said.
    it 'names the required and the current provider' do
      sessions_without_description(1)
      route_org_to('openai_compatible')

      expect(build_actor.call.errors.first).to eq(
        I18n.t('shared.ai.unavailable.pinned_elsewhere',
               provider: AiCredential.provider_display_names.fetch(pinned, pinned),
               current: AiCredential.provider_display_names.fetch('openai_compatible', 'openai_compatible'))
      )
    end

    # REGRESSION: the guard must key on the org's ROUTING, not on "an OpenAI
    # credential exists somewhere". Both were true before S1c and the difference
    # is exactly what makes this feature honest.
    it 'refuses even when a usable OpenAI system credential exists' do
      sessions_without_description(1)
      create(:ai_credential, :active, provider: 'openai')
      route_org_to('openai_compatible')

      expect(build_actor.call.code).to eq(:feature_unavailable)
    end

    it 'lets an org on the pinned provider through' do
      sessions_without_description(1)
      stub_llm_seam
      organisation.update!(ai_enabled: true, ai_provider: pinned,
                           ai_access_token: 'sk-org-own-1234567890abcdef')

      expect(build_actor.call).to be_success
    end

    # NEW IN R3, and the reason the guard was widened at all. Before, this org got
    # past the guard, ran the batch, and collected one rescued failure PER TIME
    # SESSION — the MissingCredentialError is swallowed by the generator, so the
    # flash said "0 erstellt" with N generic messages. The old narrow guard was
    # justified by "a missing credential needs a different remedy than a wrong
    # provider", and that is still true — the registry just carries the difference
    # in the REASON now, so the refusal can be both early and correct.
    it 'refuses the right provider without a usable credential, up front and by name' do
      sessions_without_description(1)
      stub_llm_seam
      allow(AiCredential).to receive(:active_for_provider).and_return(nil)
      organisation.update!(ai_enabled: true, ai_provider: pinned, ai_access_token: nil)

      result = build_actor.call

      expect(result.code).to eq(:feature_unavailable)
      expect(result.errors.first).to eq(
        I18n.t('shared.ai.unavailable.no_credential',
               provider: AiCredential.provider_display_names.fetch(pinned, pinned))
      )
      expect(CustomerDescriptionGenerator).not_to have_received(:new)
    end

    # The org shape this actually protects in production: Gemini via Vertex is live,
    # so real orgs carry ai_provider = 'google' and have no OpenAI credential at all.
    # Two reasons apply to them at once; the pin is the one they can act on.
    it 'tells a Vertex org about the pin, not about the credential it does not need' do
      sessions_without_description(1)
      stub_llm_seam
      allow(AiCredential).to receive(:active_for_provider).and_return(nil)
      organisation.update!(ai_enabled: true, ai_provider: 'google')

      result = build_actor.call

      expect(result.code).to eq(:feature_unavailable)
      expect(result.errors.first).to include(AiCredential.provider_display_names.fetch('google', 'google'))
    end

    # Ordering pin: the feature guard runs BEFORE the billed guard, so a group
    # that may not use the feature at all needs no DB reload for a billing verdict.
    it 'answers :feature_unavailable, not :group_billed, when both would refuse' do
      billed_group = create(:time_session_group, :billed, organisation: organisation, creator: user)
      route_org_to('openai_compatible')

      expect(build_actor(target: billed_group).call.code).to eq(:feature_unavailable)
    end

    # Plan §7.3, from the ACTOR's side. The gate above is ADVISORY: it answers from a
    # memoised Availability, so an opt-in withdrawn after the actor started is a state
    # it cannot see. The guarantee is the seam's own ensure_ai_enabled! — pinned for
    # Factory.for_feature in organisation_ai_availability_spec ("fail-closed
    # layering"). What is pinned HERE is the other half of that sentence: the actor
    # dies CONTROLLED when the backstop fires. No AiDisabledError escapes into the
    # controller (BaseActor#handle_unexpected_error re-raises in test, so an escape
    # would blow this example up rather than fail it quietly), and the session keeps
    # its old description instead of being written with a blank one.
    it 'survives the seam refusing after the gate said yes (advisory gate, fail-closed seam)' do
      session = sessions_without_description(1).first
      allow(Lalabase::Llm::Factory).to receive(:for_feature)
        .and_raise(Lalabase::Llm::AiDisabledError, 'opt-in withdrawn mid-flight')

      actor = build_actor
      result = actor.call

      expect(result).to be_success
      # Not vacuous: the seam really was reached and really did refuse.
      expect(Lalabase::Llm::Factory).to have_received(:for_feature).with(:customer_description, organisation)
      expect(actor.outcome.results[:failed]).to eq(1)
      expect(actor.outcome.results[:success]).to eq(0)
      expect(session.reload.customer_description).to be_nil
    end
  end

  describe 'sync outcome pass-through' do
    it 'hands the generator counters through unchanged' do
      counters = { success: 2, failed: 1, skipped: 0, errors: ['TimeSession x: kaputt'] }
      generator = instance_double(BulkCustomerDescriptionGenerator,
                                  should_use_background_job?: false, generate_all: counters)
      allow(BulkCustomerDescriptionGenerator).to receive(:new)
        .with(group, regenerate: false).and_return(generator)

      actor = build_actor
      result = actor.call

      expect(result).to be_success
      expect(actor.outcome.mode).to eq(:synchronous)
      expect(actor.outcome.results).to eq(counters)
    end
  end
end
