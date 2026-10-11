# frozen_string_literal: true

# Resolves an explicit, unchanged response in the same owned conversation.
module Assistant
  class AnalysisRevision
    def self.call(chat:, user:, context:)
      return unless context.is_a?(Hash) && context['revision_answer_id'].present?
      return unless user && ChatPolicy.new(user, chat).update?

      answer = chat.chatposts.find_by(id: context['revision_answer_id'])
      return unless answer&.savable_meeting_answer? && answer.analysis_answer_key == context['revision_answer_key']
      return unless AnalysisSources.readable?(citations: answer.analysis_context['provenance'], organisation: chat.organisation, user: user)

      answer
    end
  end
end
