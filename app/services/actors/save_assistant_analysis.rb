# frozen_string_literal: true

module Actors
  # Copies a completed, owned answer under a row lock. No generation or embedding job.
  class SaveAssistantAnalysis < BaseActor
    def initialize(chat:, answer_id:, meeting_id:, title:, current_user:, answer_key:)
      super()
      @chat = chat
      @answer_id = answer_id
      @meeting_id = meeting_id
      @title = title
      @current_user = current_user
      @answer_key = answer_key
    end

    def record
      @analysis
    end

    def perform
      answer = @chat.chatposts.lock.find_by(id: @answer_id)
      reject! unless answer && answer.analysis_answer_key == @answer_key
      eligibility = Assistant::AnalysisEligibility.new(answer: answer, user: @current_user)
      @analysis = eligibility.saved_analysis
      # A repeated request returns the original destination, including after reload
      # or if another tab submitted a different meeting choice.
      target_id = @analysis&.meeting_id || @meeting_id
      reject! unless eligibility.savable?(meeting_id: target_id)
      return if @analysis

      meeting = eligibility.meetings.find { |candidate| candidate.id == target_id }
      @analysis = meeting.meeting_analyses.create!(
        organisation: @chat.organisation, creator: @current_user,
        prompt_title: @title, prompt_snapshot: answer.analysis_context['instructions'].join("\n\n"),
        content: answer.content, is_private: true, include_in_search: false, creation_flag: false,
        source_answer_key: @answer_key,
        source_context: { 'citations' => answer.source_citations, 'coverage' => answer.source_coverage,
                          'provenance' => answer.analysis_context['provenance'] }
      )
    end

    private

    def reject!
      raise ActorError, I18n.t('assistant_analysis.unavailable')
    end
  end
end
