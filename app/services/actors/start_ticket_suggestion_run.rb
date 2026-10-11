# frozen_string_literal: true

module Actors
  # Serializes starts in both surfaces; jobs keep their existing meeting_id signature.
  class StartTicketSuggestionRun < BaseActor
    def self.from_chatpost(post:, current_user:, error_record: post)
      return if post.ticket_suggestion_meeting_id.blank?

      meeting = Meeting.where(organisation: post.chat.organisation).find_by(id: post.ticket_suggestion_meeting_id)
      result = meeting && call(meeting: meeting, chatpost: post, current_user: current_user)
      unless result&.success?
        error_record.errors.add(:base, result&.errors&.to_sentence || I18n.t('assistant_suggestions.unavailable'))
        raise ActiveRecord::RecordInvalid, error_record
      end
      result.resource
    end

    def initialize(meeting:, current_user:, chatpost: nil, retry_of: nil)
      super()
      @meeting = meeting
      @current_user = current_user
      @chatpost = chatpost
      @retry_of = retry_of
    end

    def record
      @run
    end

    def perform
      @meeting.lock!
      refuse('unavailable') unless MeetingPolicy.new(@current_user, @meeting).update?
      if @chatpost
        chat = @chatpost.chat
        scope = Lalabase::Tools::Scope.for(chat: chat, actor: @current_user)
        retrying = @retry_of&.chatpost&.chat_id == chat.id && @retry_of&.meeting_id == @meeting.id
        adopted = chat.scope_references.any? { |ref| ref['type'] == 'Meeting' && ref['id'] == @meeting.id }
        valid = chat.organisation_id == @meeting.organisation_id && ChatPolicy.new(@current_user, chat).update? &&
                (adopted || retrying) && scope&.resolve_reference(type: 'Meeting', id: @meeting.id)
        refuse('unavailable') unless valid
      end
      if @retry_of
        @retry_of.reload
        refuse('retried') unless @retry_of.retryable?
      end
      runs = MeetingTicketSuggestionRun.where(meeting: @meeting)
      expired = runs.where(status: %w[queued running]).find_by('updated_at < ?', Meeting::SUGGESTIONS_STALE_AFTER.ago)
      if expired
        expired.meeting = @meeting
        expired.mark_failed!
      end
      refuse('already_running') if runs.where(status: %w[queued running]).exists? || @meeting.suggestions_generation_running?
      refuse('ai_unavailable') unless @meeting.organisation.ai_available_for?(:meeting_ticket_suggestions).available?
      sources = if @chatpost
                  { notes: Meetings::AssistantSource.call(raw: @meeting.notes),
                    transcript: Meetings::AssistantSource.call(raw: @meeting.transcript) }
                else
                  {}
                end
      has_source = @chatpost ? sources.values.any? { |source| source[:text].present? } : @meeting.summary_source.present?
      refuse('no_content') unless has_source
      @job = Meetings::TicketSuggestionRunJob.new(meeting_id: @meeting.id)
      @run = runs.create!(organisation: @meeting.organisation, chatpost: @chatpost,
                          project_id: @meeting.project_id, meeting_title: @meeting.title,
                          project_title: @meeting.project.name, instruction: @chatpost&.content.to_s,
                          sources: sources.transform_values { |source| Meetings::AssistantSource.metadata(source: source) }, job_id: @job.job_id)
      @retry_of&.update!(retried_at: Time.current)
      # Server-only conversation metadata suppresses broadcasts even after reload,
      # without querying the optional run for every ordinary chat message.
      @chatpost&.update!(analysis_context: @chatpost.analysis_context.to_h.merge('ticket_suggestion_run_id' => @run.id))
      @meeting.update!(suggestions_creation_flag: true, suggestions_creation_error: '')
    end

    def enqueue_jobs
      run = @run
      enqueue_after_commit { Meetings::TicketSuggestionRunJob.enqueue_run(run: run) }
    end

    private

    def refuse(key)
      raise ActorError.new(I18n.t("assistant_suggestions.#{key}"), code: :unavailable)
    end
  end
end
