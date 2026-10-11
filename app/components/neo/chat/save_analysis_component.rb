# frozen_string_literal: true

module Neo
  module Chat
    # An always-visible action at an eligible answer, with its immutable target set.
    class SaveAnalysisComponent < ViewComponent::Base
      def initialize(chatpost:, current_user:, eligibility: nil)
        super()
        @chatpost = chatpost
        @current_user = current_user
        @eligibility = eligibility
      end

      def eligibility
        @eligibility ||= Assistant::AnalysisEligibility.new(answer: @chatpost, user: @current_user)
      end

      def render?
        eligibility.available? && (saved_analysis || meetings.any?)
      end

      delegate :meetings, to: :eligibility

      def saved_analysis
        return @saved_analysis if defined?(@saved_analysis)

        @saved_analysis = eligibility.saved_analysis
      end

      def saved_path
        return unless saved_analysis

        helpers.organisation_project_meeting_path(@chatpost.organisation_id, saved_analysis.meeting.project_id,
                                                  saved_analysis.meeting_id, analysis_id: saved_analysis.id,
                                                                             anchor: "meeting_analysis_#{saved_analysis.id}")
      end

      def title
        @chatpost.analysis_context['instructions'].first.to_s.lines.find(&:present?).to_s.strip.truncate(80)
      end

      def path
        helpers.organisation_assistant_chat_chatpost_analysis_path(@chatpost.organisation_id, @chatpost.chat_id, @chatpost.id)
      end
    end
  end
end
