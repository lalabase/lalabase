# frozen_string_literal: true

# Shared answer/target boundary. Rendering stays cheap; the write rechecks sources.
# Entry point: for_answers / meetings / savable? / available? / saved_analysis
module Assistant
  class AnalysisEligibility
    # A transcript resolves saved state and meeting targets in batches rather
    # than per answer. A completion broadcast uses the same rules for one answer.
    def self.for_answers(answers:, user:, organisation:)
      eligible = answers.select { |answer| new(answer: answer, user: user).available? }
      meetings = Meeting.where(organisation_id: organisation.id, id: eligible.flat_map { |answer| answer.analysis_context['meeting_ids'] }).includes(:project).index_by(&:id)
      saved = MeetingAnalysis.where(organisation_id: organisation.id, creator_id: user&.id,
                                    source_answer_key: eligible.map(&:analysis_answer_key)).includes(meeting: :project).index_by(&:source_answer_key)
      answers.index_with { |answer| new(answer: answer, user: user, meeting_records: meetings, saved_records: saved) }.transform_keys(&:id)
    end

    def initialize(answer:, user:, meeting_records: nil, saved_records: nil)
      @answer = answer
      @user = user
      @meeting_records = meeting_records
      @saved_records = saved_records
    end

    def available?
      @answer&.savable_meeting_answer? && @user &&
        ChatPolicy.new(@user, @answer.chat).update? &&
        @answer.analysis_context['provenance'].is_a?(Array) &&
        @answer.analysis_context['provenance'].all? { |source| source.is_a?(Hash) && !source['type'].to_s.start_with?('unverified_') }
    end

    def meetings
      return [] unless available?

      records = if @meeting_records
                  @meeting_records.values_at(*@answer.analysis_context['meeting_ids']).compact
                else
                  Meeting.where(organisation_id: @answer.organisation_id, id: @answer.analysis_context['meeting_ids']).includes(:project)
                end
      @meetings ||= records.select do |meeting|
        MeetingPolicy.new(@user, meeting).update?
      end
    end

    def savable?(meeting_id:)
      meetings.any? { |meeting| meeting.id == meeting_id } &&
        AnalysisSources.readable?(citations: @answer.analysis_context['provenance'], organisation: @answer.organisation, user: @user)
    end

    def saved_analysis
      return unless available?

      saved = if @saved_records
                @saved_records[@answer.analysis_answer_key]
              else
                MeetingAnalysis.where(organisation_id: @answer.organisation_id, creator_id: @user.id)
                               .includes(meeting: :project).find_by(source_answer_key: @answer.analysis_answer_key)
              end
      saved if saved && MeetingAnalysisPolicy.new(@user, saved).show?
    end
  end
end
