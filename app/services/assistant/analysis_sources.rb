# frozen_string_literal: true

# Rechecks source records with existing policies; unknown provenance fails closed.
# Entry point: readable? / publishable?

module Assistant
  class AnalysisSources
    MODELS = { 'project' => 'Project', 'ticket' => 'Ticket', 'post' => 'Post', 'note' => 'Note',
               'document' => 'Document', 'documentation' => 'DocumentationPage',
               'meeting' => 'Meeting', 'meeting_analysis' => 'MeetingAnalysis',
               'vision' => 'ProjectLayer4Vision', 'capability' => 'ProjectCapability', 'symbol' => 'CodeSymbol' }.freeze

    def self.readable?(citations:, organisation:, user:)
      return false unless user && citations.is_a?(Array)

      return false unless citations.all? { |citation| citation.is_a?(Hash) }

      # Source identities grow with the conversation. Batch each table once at the
      # write boundary, while still evaluating each record's existing policy.
      records = citations.group_by { |citation| citation['type'] }.to_h do |type, group|
        model = MODELS[type]
        rows = model ? model.constantize.where(organisation_id: organisation.id, id: group.pluck('id')).to_a : []
        [type, rows.index_by(&:id)]
      end
      citations.all? do |citation|
        next true if citation['type'] == 'help_page'

        model = MODELS[citation['type']]
        next false unless model

        record = records.dig(citation['type'], citation['id'])
        next false unless record

        policy_record = case record
                        when DocumentationPage then record.documentation_set
                        when CodeSymbol then record.project_repository
                        when ProjectLayer4Vision, ProjectCapability
                          next ProjectRepositoryPolicy.new(user, record.project).show?
                        else record
                        end
        next false unless Pundit.policy!(user, policy_record).show?
        next true unless citation.key?('post_ids')
        next false unless record.is_a?(Ticket) && citation['post_ids'].is_a?(Array)

        posts = record.posts.where(id: citation['post_ids']).to_a
        posts.size == citation['post_ids'].uniq.size && posts.all? { |post| PostPolicy.new(user, post).show? }
      end
    end

    # Meeting readers share the target meeting's source rights. Other objects have
    # independent area/private gates, so their derived text cannot be released through
    # this meeting's publication switch. Legacy meeting-only analyses are unchanged.
    def self.publishable?(context:, meeting:)
      return true if context.nil?

      provenance = context['provenance']
      provenance.is_a?(Array) && provenance.present? && provenance.all? do |citation|
        citation['type'] == 'help_page' ||
          (citation['type'] == 'project' && citation['id'] == meeting.project_id) ||
          (citation['type'] == 'meeting' && citation['id'] == meeting.id && citation['project_id'] == meeting.project_id)
      end
    end
  end
end
