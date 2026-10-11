# frozen_string_literal: true

# app/services/actors/generate_group_customer_descriptions.rb
#
# Tier 2 (decision D4): owns #call because the LLM round-trip (sync path, up to
# 10 calls of several seconds each) must not hang in a DB transaction — same
# reason as CreateAiPost — and the sync/async fork (job enqueue XOR synchronous
# partial-success write) does not fit the #perform template.
#
# Refuses billed groups BEFORE any LLM call or enqueue (plan §9.8-5): no paid
# calls for guaranteed prevent_changes_when_billed failures. Defense-in-depth
# twin: BulkCustomerDescriptionGenerator#generate_all carries the same billed
# refuse for the async job path (enqueue-then-billed race, retry_on replays).
#
# Refuses orgs that cannot use the feature at all, for the same structural reason
# (R3, doc/ai_feature_registry_plan.md): :customer_description is pinned to OpenAI
# and cannot follow the org's choice, so the feature is switched OFF and explained
# rather than silently routed there — and the same gate now also names a missing
# credential instead of letting it surface per session. Same twin in generate_all:
# the org can switch providers, or lose its credential, between enqueue and
# execution.
module Actors
  class GenerateGroupCustomerDescriptions < BaseActor
    # mode: :enqueued | :synchronous; results: generate_all counters (sync only).
    Outcome = Struct.new(:mode, :results, keyword_init: true)

    attr_reader :outcome

    def initialize(group:, regenerate:, current_user:)
      super()
      @group = group
      @regenerate = regenerate
      @current_user = current_user
    end

    def record
      @group
    end

    def call
      with_error_mapping do
        with_actor_context do
          guard_feature_available!
          guard_group_not_billed!
          generator = BulkCustomerDescriptionGenerator.new(@group, regenerate: @regenerate)
          if generator.should_use_background_job?
            # Guard compliance: actors never enqueue raw; without an open
            # transaction the block runs immediately. Job args stay
            # bit-identical to the previous controller enqueue (hash form).
            enqueue_after_commit do
              GenerateCustomerDescriptionsJob.perform_later(
                { time_session_group_id: @group.id, regenerate: @regenerate, user_id: @current_user.id }
              )
            end
            @outcome = Outcome.new(mode: :enqueued)
          else
            # Deliberately NO transaction: per-session partial success is the
            # existing contract of generate_all (each session commits on its own).
            @outcome = Outcome.new(mode: :synchronous, results: generator.generate_all)
          end
          success(@group)
        end
      end
    end

    private

    # The whole feature question, asked once (R3): may this org use
    # :customer_description at all? The same registry row
    # CustomerDescriptionGenerator routes on, so a refusal here and the provider the
    # call would have reached are two readings of one line.
    #
    # BEFORE the billed guard on purpose: this is the cheaper refusal (no reload,
    # no DB round-trip) and the more fundamental one — a group that may not use
    # this feature at all needs no billing verdict.
    #
    # Wider than the S4 predecessor, which asked the PROVIDER question alone
    # (ai_pinned_elsewhere?) and deliberately let a missing credential fall through
    # to MissingCredentialError, because answering "this feature needs OpenAI" to an
    # admin whose OpenAI key merely expired would have sent them to the wrong
    # screen. That objection is what the registry dissolves: the reason travels with
    # the answer, so :no_credential now says "no usable access for OpenAI" instead —
    # up front, once, and localized, rather than once per time session out of the
    # per-session rescue.
    def guard_feature_available!
      availability = @group.organisation&.ai_available_for?(:customer_description)
      return if availability&.available?

      raise ActorError.new(
        Lalabase::Llm::FeatureRegistry.unavailable_hint(availability, @group.organisation),
        code: :feature_unavailable
      )
    end

    # Reload inside the guard (T1 pattern, plan §9.8-1): reject a group that was
    # invoiced concurrently; generating for a billed group would only burn LLM
    # budget and then fail per session at prevent_changes_when_billed.
    def guard_group_not_billed!
      return unless @group.reload.billed?

      raise ActorError.new(
        I18n.t('services.actors.generate_group_customer_descriptions.group_billed'),
        code: :group_billed
      )
    end
  end
end
