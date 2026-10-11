# frozen_string_literal: true

# Freezes server-observed sources and explicit references for one completed answer.
# Entry point: call / input

module Assistant
  class AnalysisContext
    # These tools return complete source identities (or public product help).
    # Listing/activity/code tools may omit or cap citations; never certify their
    # partial citation list as complete provenance for a saved result.
    COMPLETE_SOURCE_TOOLS = %w[get_meeting get_note get_document search_help help_contents get_help_page].freeze

    def self.input(chat:, instruction:)
      { 'references' => chat.scope_references.deep_dup, 'instruction' => instruction }
    end

    def self.call(question:, history:, citations:, reference_citations: [], tool_calls: [], revision: nil)
      return nil unless question&.analysis_context.is_a?(Hash)

      input = question.analysis_context
      references = Array(input['references']).select { |r| r['type'] == 'Meeting' }.pluck('id')
      # Choosing an earlier result explicitly also adopts its fixed meeting targets,
      # even if the conversation's chips changed since that answer was produced.
      references |= Array(revision.analysis_context['meeting_ids']) if revision
      observed = citations.filter_map { |c| c['id'] if c['type'] == 'meeting' }
      observed |= Array(revision.analysis_context['meeting_ids']) if revision
      # All sources that entered conversation history matter, even if the model marked
      # them unused. Its attribution is a display hint, never a disclosure permission.
      provenance = history.select(&:assistant?).flat_map do |post|
        Array(post.analysis_context&.fetch('provenance', nil)) + post.source_citations
      end
      provenance.concat(Array(revision.analysis_context['provenance'])) if revision
      # Old answers and interrupted streams lack complete source metadata.
      # Their complete provenance cannot be reconstructed from visible citations.
      provenance << { 'type' => 'unverified_history' } if history.any? { |post| post.assistant? && post.analysis_context.nil? }
      provenance << { 'type' => 'unverified_tool_sources' } if tool_calls.any? { |call| call['succeeded'] && !complete_sources?(call) }
      instructions = revision ? Array(revision.analysis_context['instructions']) : []
      {
        'question_id' => question.id,
        'meeting_ids' => references & observed,
        'instructions' => instructions + [input['instruction']],
        'provenance' => (provenance + citations + reference_citations).uniq
      }
    end

    def self.complete_sources?(call)
      COMPLETE_SOURCE_TOOLS.include?(call['tool']) ||
        (call['tool'] == 'get_ticket' && call.dig('args', 'ticket_id').present? && call.dig('args', 'project').blank?)
    end
    private_class_method :complete_sources?
  end
end
