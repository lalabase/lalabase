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

    # The page number is read by Pagination::Page, the rule of every list: a list
    # or a hash is page 1, and a page behind the end is empty without slicing at an
    # offset Ruby cannot hold (`?page=` with thirty digits raised RangeError).
    current = Pagination::Page.new(count: total, page: options[:page], limit: normalize_per_page(options[:per_page]))

    {
      items: current.past_end? ? [] : all_results[current.offset, current.limit],
      total: total,
      page: current.page,
      per_page: current.limit
    }
  end

  private

  # Single-type lists stay in SQL through count, ordering and pagination.
  # Even callers without paging options receive a bounded list, never transcripts.
  # A page behind the end is the last page here, as it always was on this path.
  def paginate_relation(scope, options)
    total = scope.unscope(:select, :order).count
    current = Pagination::Page.new(count: total, page: options[:page], limit: normalize_per_page(options[:per_page]),
                                   past_end: :last)
    { items: scope.limit(current.limit).offset(current.offset).to_a,
      total: total, page: current.page, per_page: current.limit }
  end

  # Absent, no number, below 1, a list or a hash: the default.
  def normalize_per_page(value)
    [Pagination::Page.size(value) || DEFAULT_PER_PAGE, MAX_PER_PAGE].min
  end

  def empty_result(per_page: DEFAULT_PER_PAGE)
    { items: [], total: 0, page: 1, per_page: per_page }
  end
end
