# frozen_string_literal: true

# app/services/actors/regenerate_chatpost.rb
#
# Re-enqueues the answer for ONE assistant post (the "regenerate" action on an
# answer). The pre-checks are domain failures with precise codes (#103 pattern):
# :not_found (unknown/foreign chatpost id), :not_regenerable (not an assistant
# post) — the controller collapses them to the HTTP statuses the old inline
# checks produced. No job on a rejected pre-check (the raise precedes
# #enqueue_jobs, which only runs on success).
#
# 2026-07-19: the style used to ride along as a one-off parameter (the four
# "shorter/simpler/…" pills, which also nudged the stored level as a side
# effect). The style now lives solely in the user's ChatStylePreference, set
# explicitly via the pills under the composer, so this actor no longer writes
# anything — it just re-runs the answer, which picks the current level up
# through ChatResponseJob#style_directives.

module Actors
  class RegenerateChatpost < BaseActor
    ERROR_SCOPE = 'services.actors.regenerate_chatpost'

    def initialize(chat:, chatpost_id:, current_user:)
      super()
      @chat = chat
      @chatpost_id = chatpost_id
      @current_user = current_user
    end

    # The assistant post being regenerated (nil before the lookup — safe_record
    # covers the failure paths).
    def record
      @target
    end

    def perform
      @target = @chat.chatposts.find_by(id: @chatpost_id)
      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.not_found"), code: :not_found) if @target.nil?

      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.not_regenerable"), code: :not_regenerable) unless @target.assistant?
    end

    def enqueue_jobs
      chat = @chat
      target_id = @target.id
      acting_user_id = @current_user.id

      enqueue_after_commit do
        ChatResponseJob.perform_later(chat, regenerate_chatpost_id: target_id, acting_user_id: acting_user_id)
      end
    end
  end
end
