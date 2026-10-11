# frozen_string_literal: true

# app/services/smart_folder_service.rb
class SmartFolderService
  MAX_PER_PAGE = 100
  DEFAULT_PER_PAGE = 25

  attr_reader :smart_folder, :current_user

  def initialize(smart_folder, current_user = nil)
    @smart_folder = smart_folder
    @current_user = current_user || smart_folder.user
    @query_builder = SmartFolderQueryBuilder.new(smart_folder, @current_user)
  end

  def fetch_results(options = {})
    return empty_result(per_page: normalize_per_page(options[:per_page])) unless smart_folder.accessible_by?(current_user)

    all_results = @query_builder.build_results_query
    return paginate_relation(all_results, options) if all_results.is_a?(ActiveRecord::Relation)

    total = all_results.size

    # Without explicit pagination options, return ALL matches: folder FILTERS
    # (tickets/times/lists) call without options and filter further themselves —
    # the earlier implicit default of 25 silently truncated them. The QueryBuilder
    # caps at RESULTS_PER_MODEL_LIMIT (1000) per model anyway.
    if options[:page].blank? && options[:per_page].blank?
      return {
        items: all_results,
        total: total,
        page: 1,
        per_page: total
      }
    end

    page = normalize_page(options[:page])
    per_page = normalize_per_page(options[:per_page])
    offset = (page - 1) * per_page
    paginated_results = all_results[offset, per_page] || []

    {
      items: paginated_results,
      total: total,
      page: page,
      per_page: per_page
    }
  end

  private

  # Single-type lists stay in SQL through count, ordering and pagination.
  # Even callers without paging options receive a bounded list, never transcripts.
  def paginate_relation(scope, options)
    per_page = normalize_per_page(options[:per_page])
    total = scope.unscope(:select, :order).count
    page = [normalize_page(options[:page]), [(total.to_f / per_page).ceil, 1].max].min
    { items: scope.limit(per_page).offset((page - 1) * per_page).to_a,
      total: total, page: page, per_page: per_page }
  end

  def normalize_page(value)
    page = value.to_i
    page > 0 ? page : 1
  end

  def normalize_per_page(value)
    per_page = value.to_i
    per_page = DEFAULT_PER_PAGE unless per_page > 0
    [per_page, MAX_PER_PAGE].min
  end

  def empty_result(per_page: DEFAULT_PER_PAGE)
    { items: [], total: 0, page: 1, per_page: per_page }
  end
end
