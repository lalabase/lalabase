# frozen_string_literal: true

# app/services/actors/create_chatpost.rb
#
# Appends a user message to an EXISTING chat and enqueues the AI answer. The
# actor is origin-agnostic on purpose (D8/E1): it takes a `chat:` and does not
# care whether that is a project thread or an org-wide thread; every surface
# enqueues through it.
#
# Since S4-T1 this is the ONE site that assembles a chatpost's attributes
# (content + server-side user/organisation, role via Chatpost#set_initial_role);
# the lane that used to carry a deliberate twin of it is gone.

module Actors
  class CreateChatpost < BaseActor
    def initialize(chat:, params:, current_user:)
      super()
      @chat = chat
      @params = params
      @current_user = current_user
    end

    # The chatpost — on failure it is the invalid record for the composer re-render.
    def record
      @chatpost
    end

    def perform
      @chatpost = @chat.chatposts.build(@params.except(:revision_answer_id, :revision_answer_key))
      # Author server-side, never from params; organisation explicitly from the
      # chat (parity — not from the ambient tenant).
      @chatpost.user = @current_user
      @chatpost.organisation = @chat.organisation
      # role is assigned by Chatpost#set_initial_role (before_save) — first post
      # in a chat becomes 'system', the rest default to 'user'. Single source;
      # don't duplicate that rule here.
      @chatpost.analysis_context = Assistant::AnalysisContext.input(chat: @chat, instruction: @chatpost.content)
      if @params[:revision_answer_id].present?
        revision_context = { 'revision_answer_id' => @params[:revision_answer_id], 'revision_answer_key' => @params[:revision_answer_key] }
        @chatpost.analysis_context.merge!(revision_context)
        revision = Assistant::AnalysisRevision.call(chat: @chat, user: @current_user, context: revision_context)
        unless revision
          @chatpost.errors.add(:base, I18n.t('assistant_analysis.revision_unavailable'))
          raise ActiveRecord::RecordInvalid, @chatpost
        end
      end
      @chatpost.save!
      start_ticket_suggestions
      # Parity for the turbo_stream response (create.turbo_stream.erb needs both
      # fresh: post enum/role state + the chat's post order).
      @chatpost.reload
      @chat.reload
    end

    def start_ticket_suggestions
      @suggestion_run = Actors::StartTicketSuggestionRun.from_chatpost(post: @chatpost, current_user: @current_user, error_record: record)
    end

    def enqueue_jobs
      return if @suggestion_run

      chat = @chat
      acting_user_id = @current_user.id
      question_id = @chatpost.id
      # acting_user_id (v1.5): the asking user — the job resolves their
      # persistent style level from it.
      enqueue_after_commit { ChatResponseJob.perform_later(chat, acting_user_id: acting_user_id, question_chatpost_id: question_id) }
    end
  end
end
