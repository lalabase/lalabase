# frozen_string_literal: true

# Queries a permission-scoped meeting list, including saved and temporary conditions.
module Meetings
  class ListQuery
    SORT_COLUMNS = %w[title occurred_at duration_minutes created_at updated_at].freeze
    LIST_COLUMNS = %i[id project_id organisation_id creator_id title occurred_at duration_minutes created_at updated_at].freeze

    def self.call(scope:, search: nil, search_mode: 'content', filters: {}, operators: {}, smart_folder: nil, apply_folder_rules: true, sort: {})
      query = scope
      query = SmartFolderQueryBuilder.new(smart_folder).filter_relation(query) if smart_folder && apply_folder_rules
      query = AdHocFilterService.new(nil, filters, operators).apply(query)
      if search.present?
        query = if search_mode == 'title_only'
                  query.where('meetings.title ILIKE ?', "%#{Meeting.sanitize_sql_like(search.to_s)}%")
                else
                  query.search_by_content(search)
                end
      end
      column = sort['column'].presence || smart_folder&.effective_sort_column || 'occurred_at'
      column = 'occurred_at' unless SORT_COLUMNS.include?(column)
      direction = sort['direction'].presence || smart_folder&.effective_sort_direction || 'desc'
      direction = 'desc' unless %w[asc desc].include?(direction)
      # Ties by the time a meeting was entered: occurred_at has minutes only, and
      # a meeting just saved from the "+" belongs at the top, not wherever its
      # random id puts it. The id makes the order total.
      query.reorder(column => direction, created_at: direction, id: direction)
           .select(*LIST_COLUMNS).preload(:meeting_participants, :creator)
    end
  end
end
