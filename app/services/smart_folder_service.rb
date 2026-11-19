# frozen_string_literal: true

# The results of a saved view (SmartFolder): what its rules find, for the reader
# who asks. One page of them, or every result for a list that filters them further.
#
# Entry point: fetch_results
class SmartFolderService
  MAX_PER_PAGE = 100
  DEFAULT_PER_PAGE = 25

  attr_reader :smart_folder, :current_user

  def initialize(smart_folder:, current_user: nil)
    @smart_folder = smart_folder
    @current_user = current_user || smart_folder.user
    @query_builder = SmartFolderQueryBuilder.new(smart_folder, @current_user)
  end

  # => { items:, total:, page:, per_page: }
  #
  # page:, per_page: as a request names them, read by Pagination::Page like every
  # list: a value that names neither (absent, blank, no number, a list or a hash)
  # is page 1 and DEFAULT_PER_PAGE, never "everything".
  #
  # unpaged: every result instead of one page, for the lists that filter the
  # folder's results further themselves (tickets, times). An implicit default of
  # 25 once truncated those silently, and a blank page and page size once meant
  # "everything" for whoever forwarded the request's parameters: so it is asked
  # for by name. The QueryBuilder caps at RESULTS_PER_MODEL_LIMIT (1000) per
  # model. A folder of one type stays in SQL and is paged anyway
  # (#paginate_relation).
  def fetch_results(page: nil, per_page: nil, unpaged: false)
    return empty_result(per_page: page_size(per_page)) unless smart_folder.accessible_by?(current_user)

    all_results = @query_builder.build_results_query
    return paginate_relation(all_results, page: page, per_page: per_page) if all_results.is_a?(ActiveRecord::Relation)

    total = all_results.size
    return { items: all_results, total: total, page: 1, per_page: total } if unpaged

    # A page behind the end is empty, without slicing at an offset Ruby cannot
    # hold (`?page=` with thirty digits raised RangeError).
    current = Pagination::Page.new(count: total, page: page, limit: page_size(per_page))

    {
      items: current.past_end? ? [] : all_results[current.offset, current.limit],
      total: total,
      page: current.page,
      per_page: current.limit
    }
  end

  private

  # Single-type lists stay in SQL through count, ordering and pagination.
  # Even callers that ask for every result receive a bounded list, never transcripts.
  # A page behind the end is the last page here, as it always was on this path.
  def paginate_relation(scope, page:, per_page:)
    total = scope.unscope(:select, :order).count
    current = Pagination::Page.new(count: total, page: page, limit: page_size(per_page), past_end: :last)
    { items: scope.limit(current.limit).offset(current.offset).to_a,
      total: total, page: current.page, per_page: current.limit }
  end

  def page_size(value)
    Pagination::Page.size(value, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
  end

  def empty_result(per_page: DEFAULT_PER_PAGE)
    { items: [], total: 0, page: 1, per_page: per_page }
  end
end
