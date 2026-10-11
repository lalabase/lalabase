# frozen_string_literal: true

# Query object for the Knowledge list (Notes + Documents + future types).
#
# Replaces the former Ruby merge (load arrays, sort, slice) with a normalized
# SQL UNION (PE-E of the Knowledge filter rework): each type from
# Knowledge::TypeRegistry provides one arm (id, item_type, title, created_at,
# updated_at); pagination, sorting, and counting run DB-side over the UNION.
# The objects of the current page are then loaded type-wise with eager loading
# afterwards (one IN query per type).
#
# Filter pipeline per arm (analogous to TicketSearchQuery):
#   type selection -> smart folder SQL predicates -> search -> ad-hoc filters
#
# SmartFolder predicates remain SQL relations; only the resulting page is
# materialized. No preview limit or full-text row loading precedes pagination.
class KnowledgeSearchQuery
  Result = Struct.new(:items, :pagy, keyword_init: true)

  SORTABLE_COLUMNS = %w[created_at updated_at title].freeze
  DEFAULT_SORT_COLUMN = 'created_at'
  DEFAULT_SORT_DIRECTION = 'desc'

  # Options (analogous to TicketSearchQuery):
  #   current_user, accessible_type_keys (registry keys with read access),
  #   active_smart_folder, filter_params/operator_params (ad-hoc filters),
  #   per_page, apply_folder_query (default true). With apply_folder_query
  #   false the folder still narrows the types and supplies the default sort,
  #   but its rules are not applied: the edited view (AdHocFilterable, S3a)
  #   hands the effective conditions in as filter_params instead.
  #   builtin_type (default: params[:type]): the built-in type view (S7);
  #   nil while the reader edited it, because then filter_params['type'], the
  #   type as a condition, is the only type restriction that counts.
  def initialize(project, params = {}, options = {})
    @project = project
    @params = params
    @current_user = options[:current_user]
    @accessible_type_keys = options.fetch(:accessible_type_keys, [])
    @active_smart_folder = options[:active_smart_folder]
    @apply_folder_query = options.fetch(:apply_folder_query, true)
    @builtin_type = (options.key?(:builtin_type) ? options[:builtin_type] : params[:type]).to_s
    @filter_params = options[:filter_params].presence || {}
    @operator_params = options[:operator_params].presence || {}
    @per_page = options.fetch(:per_page, 10)
  end

  def call
    arm_sqls = type_keys_to_query.filter_map { |key| build_arm_sql(key) }
    return empty_result if arm_sqls.empty?

    union_sql = arm_sqls.map { |sql| "(#{sql})" }.join(' UNION ALL ')
    total = connection.select_value("SELECT COUNT(*) FROM (#{union_sql}) AS knowledge_union").to_i
    pagy = build_pagy(total)
    rows = connection.select_all(<<~SQL.squish)
      SELECT id, item_type FROM (#{union_sql}) AS knowledge_union
      ORDER BY #{order_sql}
      LIMIT #{pagy.limit.to_i} OFFSET #{pagy.offset.to_i}
    SQL

    Result.new(items: materialize(rows), pagy: pagy)
  end

  private

  attr_reader :project, :params, :current_user, :accessible_type_keys,
              :active_smart_folder, :apply_folder_query, :builtin_type, :filter_params, :operator_params, :per_page

  # Type selection: access rights ∩ the type condition (filter[type][], S7)
  # ∩ the built-in type view ∩ smart folder target type (PE-B)
  def type_keys_to_query
    keys = Knowledge::TypeRegistry.keys & accessible_type_keys
    keys &= requested_type_keys if requested_type_keys.any?
    keys &= [builtin_type] if Knowledge::TypeRegistry.key?(builtin_type)
    keys &= smart_folder_type_keys if active_smart_folder
    keys
  end

  # The type as a condition: filter[type][] from the address or from the
  # effective set of an edited view. Unknown keys fall out, like an unknown
  # ?type= does; the AdHocFilterService skips the key, it is no column.
  def requested_type_keys
    @requested_type_keys ||= Array(filter_params['type'] || filter_params[:type]).map(&:to_s) & Knowledge::TypeRegistry.keys
  end

  def smart_folder_type_keys
    target = active_smart_folder.target_object_type
    keys = Knowledge::TypeRegistry.keys_for_smart_folder_target(target)
    target == 'All' ? keys.select { |key| SmartFolderQueryBuilder::ALL_MODELS.key?(Knowledge::TypeRegistry.fetch(key)[:model_name]) } : keys
  end

  def build_arm_sql(key)
    entry = Knowledge::TypeRegistry.fetch(key)
    scope = entry[:base_scope].call(project)

    if active_smart_folder && apply_folder_query
      return nil unless active_smart_folder.accessible_by?(current_user)

      scope = smart_folder_query_builder.filter_relation(scope)
    end

    scope = entry[:search_scope].call(scope, like_term, search_mode) if search_term.present?
    scope = ad_hoc_filter_service.apply(scope) if filter_params.present?

    table = scope.table_name
    scope.select(
      "#{table}.id AS id, '#{key}' AS item_type, #{entry[:title_sql]} AS title, " \
      "#{table}.created_at AS created_at, #{table}.updated_at AS updated_at"
    ).to_sql
  end

  def smart_folder_query_builder
    @smart_folder_query_builder ||= SmartFolderQueryBuilder.new(active_smart_folder, current_user)
  end

  def ad_hoc_filter_service
    @ad_hoc_filter_service ||= AdHocFilterService.new(project, filter_params, operator_params)
  end

  def materialize(rows)
    records = {}
    rows.to_a.group_by { |row| row['item_type'] }.each do |key, type_rows|
      entry = Knowledge::TypeRegistry.fetch(key)
      loaded = entry[:model_name].constantize
                                 .where(id: type_rows.map { |row| row['id'] })
                                 .includes(*entry[:includes])
                                 .index_by(&:id)
      type_rows.each { |row| records[[key, row['id']]] = loaded[row['id']] }
    end

    rows.to_a.filter_map { |row| records[[row['item_type'], row['id']]] }
  end

  # Page clamping as in the previous Knowledge behavior:
  # page <= 0 -> 1, page > last page -> last page.
  def build_pagy(total)
    total_pages = [(total.to_f / per_page).ceil, 1].max
    page = [[params[:page].to_i, 1].max, total_pages].min
    Pagy.new(count: total, page: page, limit: per_page)
  end

  def empty_result
    Result.new(items: [], pagy: Pagy.new(count: 0, page: 1, limit: per_page))
  end

  def order_sql
    if SORTABLE_COLUMNS.include?(sort_column)
      column = sort_column
      direction = %w[asc desc].include?(sort_direction.to_s) ? sort_direction : DEFAULT_SORT_DIRECTION
    else
      # Non-whitelisted column: discard the sort request as a whole
      column = DEFAULT_SORT_COLUMN
      direction = DEFAULT_SORT_DIRECTION
    end

    if column == 'title'
      "title #{direction.upcase} NULLS LAST, created_at DESC"
    else
      "#{column} #{direction.upcase}"
    end
  end

  # Explicit sort param > smart folder sorting > default
  def sort_column
    params.dig(:sort, :column).presence || active_smart_folder&.effective_sort_column
  end

  def sort_direction
    params.dig(:sort, :direction).presence || active_smart_folder&.effective_sort_direction
  end

  def search_term
    @search_term ||= params[:search].to_s.strip
  end

  def like_term
    "%#{ActiveRecord::Base.sanitize_sql_like(search_term)}%"
  end

  def search_mode
    params[:search_mode].presence || 'content'
  end

  def connection
    ActiveRecord::Base.connection
  end
end
