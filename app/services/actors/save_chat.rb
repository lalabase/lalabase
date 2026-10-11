# frozen_string_literal: true

# app/services/actors/save_chat.rb
#
# Creates a chat with its first (nested) posts and enqueues the first AI answer.
# The thread's owner and the post author are both forced to current_user
# server-side (never from params — mass-assignment contract), the posts'
# organisation comes from the request tenant via acts_as_tenant (parity with the
# old controller). On failure the
# Result carries the invalid chat (with errors) for the form re-render.
#
# S3a T2: `project: nil` creates an ORG-WIDE personal thread (Chat#org_thread?).
# Same owner contract, organisation from the request tenant; the model's
# invariant (org thread requires an owner) rejects any path that skips the
# owner assignment below.

module Actors
  class SaveChat < BaseActor
    # projekt_chat_abbau dropped `project:`. It selected which collection the new
    # thread was built through, and there is only one kind of thread left.
    def initialize(params:, current_user:, reference_keys: [])
      super()
      @params = params
      @reference_keys = reference_keys
      @current_user = current_user
    end

    # The chat — on failure it is the invalid record carrying the errors.
    def record
      @chat
    end

    def perform
      @chat = Chat.new(@params)
      # Owner and author are both set server-side, never from params (mass-assignment
      # contract). This is the ONE place a thread gets its owner, so a spoofed
      # user_id in the params has to lose here or nowhere.
      @chat.user = @current_user
      @chat.chatposts.each { |chatpost| chatpost.user = @current_user }
      assign_draft_references
      @chat.chatposts.each do |post|
        post.analysis_context = Assistant::AnalysisContext.input(chat: @chat, instruction: post.content)
      end
      @chat.save!
      start_ticket_suggestions
      @chat.reload # so the chatposts render in creation order in the response
    end

    # Resolve through the same permission boundary as AddChatReference, before
    # the first save/job. On failure, retain only readable references for retry.
    def assign_draft_references
      keys = Array(@reference_keys).reject(&:blank?).uniq
      return if keys.empty?

      max = Assistant::ReferenceRegistry::MAX_REFERENCES
      if keys.size > max
        @chat.errors.add(:base, I18n.t('flash.assistant_chats.reference_limit', count: max))
        raise ActiveRecord::RecordInvalid, @chat
      end

      pairs = keys.filter_map { |key| Assistant::ReferenceRegistry.parse_key(key) }
      @chat.scope_references = pairs.map { |pair| Assistant::ReferenceRegistry.stored_entry(**pair) }.uniq
      # Scope resolves the collection in batches (one query per type), using
      # exactly the same access rules as the existing reference write/read path.
      resolved = Lalabase::Tools::Scope.for(chat: @chat, actor: @current_user).references
      invalid = pairs.size != keys.size || resolved.size != @chat.scope_references.size
      @chat.scope_references = resolved.map do |record|
        Assistant::ReferenceRegistry.stored_entry(type: record.class.name, id: record.id)
      end
      return unless invalid

      @chat.errors.add(:base, I18n.t('flash.assistant_chats.reference_error'))
      raise ActiveRecord::RecordInvalid, @chat
    end

    def start_ticket_suggestions
      @suggestion_run = Actors::StartTicketSuggestionRun.from_chatpost(post: @chat.chatposts.first, current_user: @current_user, error_record: record)
    end

    def enqueue_jobs
      return if @suggestion_run

      chat = @chat
      # Deliberately WITHOUT acting_user_id (parity, plan F3): the FIRST answer
      # of a new chat resolves the neutral style default; follow-up posts and
      # regenerates thread the acting user. Unifying this is a separate
      # follow-up decision, not part of the seam conversion.
      question_id = chat.chatposts.not_assistant.order(:created_at).last&.id
      enqueue_after_commit { ChatResponseJob.perform_later(chat, question_chatpost_id: question_id) }
    end
  end
end
