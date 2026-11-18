# frozen_string_literal: true

# One page of a list: which rows it holds and the numbers a pagination bar shows.
#
# The application's own, since 2026-11-18. It replaced a gem of which the lists
# used the arithmetic and nothing else. Three rules live here and nowhere else:
#
# * A page nobody can show is answered, never refused. Below 1, no number or a
#   list (`?page[]=1`) is page 1. The value comes from the address bar, and a
#   typo or a crawler gets a page, not a 500.
# * A page past the end is an EMPTY page that links back to the last one
#   (`past_end: :empty`, the default), or the last page itself (`:last`). Empty is
#   what every list answered before; a list that appends pages (the inbox) needs
#   it, because the last page again would be the same rows twice.
# * The page size is the caller's. A size below 1 is a programming error and raises.
#
# Entry point: of
module Pagination
  class Page
    # How many links the full bar shows before it leaves pages out (#series).
    SERIES_SIZE = 10
    # From this many links on, the first and the last page stay in the bar.
    ENDS_FROM_SIZE = 7
    PAST_END = %i[empty last].freeze

    attr_reader :count, :page, :limit

    # => [Page, the relation narrowed to that page]
    #
    # count: a caller that knows the total hands it in. Counting a GROUPED relation
    # returns a Hash of every group; its size is the number of rows, but the whole
    # result set was loaded to learn it.
    def self.of(scope, page:, limit:, count: nil, past_end: :empty)
      current = new(count: count || total_of(scope), page: page, limit: limit, past_end: past_end)
      # Without a query: an offset built from any number somebody types leaves
      # PostgreSQL's range long before it leaves Ruby's.
      rows = current.past_end? ? scope.none : scope.offset(current.offset).limit(current.limit)
      [current, rows]
    end

    def self.total_of(scope)
      total = scope.count(:all)
      total.is_a?(Hash) ? total.size : total
    end

    # A page as it arrives in a request. => Integer, never below 1
    def self.number(value)
      number =
        case value
        when Integer then value
        when String then value.to_i
        when Float then value.finite? ? value.to_i : 1
        else 1
        end
      [number, 1].max
    end

    def initialize(count:, page:, limit:, past_end: :empty)
      raise ArgumentError, "past_end is :empty or :last, got #{past_end.inspect}" unless PAST_END.include?(past_end)

      @limit = Integer(limit, exception: false)
      raise ArgumentError, "limit must be a whole number of at least 1, got #{limit.inspect}" unless @limit&.positive?

      @count = [Integer(count), 0].max
      @past_end = past_end
      number = self.class.number(page)
      @page = past_end == :last ? [number, pages].min : number
      freeze
    end

    # A list without rows still has one (empty) page.
    def pages
      [(count.to_f / limit).ceil, 1].max
    end

    # Asked for a page behind the last one: it holds no rows.
    def past_end?
      page > pages
    end

    def offset
      (page - 1) * limit
    end

    # Position of the first and the last row of this page, counted from 1; both 0
    # when the page holds no row.
    def from
      past_end? ? 0 : [offset + 1, count].min
    end

    def to
      past_end? ? 0 : [offset + limit, count].min
    end

    def prev
      return pages if past_end?

      page - 1 unless page == 1
    end

    def next
      page + 1 if page < pages
    end

    # The same list, another page.
    def with_page(number)
      self.class.new(count: count, page: number, limit: limit, past_end: @past_end)
    end

    # The links of a full bar: Integers for pages, the current page as a String,
    # :gap where pages are left out. With 30 pages on page 12:
    #   [1, :gap, 9, 10, 11, "12", 13, 14, :gap, 30]
    # Past the end the bar is the last page's, and no link is the current one.
    def series(size: SERIES_SIZE)
      numbers = size >= pages ? (1..pages).to_a : window(size)
      numbers.map { |number| number == page ? number.to_s : number }
    end

    def as_json(*)
      { count: count, page: page, limit: limit, pages: pages, prev: prev, next: self.next, from: from, to: to }
    end

    private

    # `size` consecutive pages around the current one, pushed back inside the list
    # at either end. A wide bar keeps the first and the last page and marks what it
    # leaves out.
    def window(size)
      left = (size - 1) / 2
      start = ([page, pages].min - left).clamp(1, pages - size + 1)
      numbers = (start...(start + size)).to_a
      return numbers if size < ENDS_FROM_SIZE

      numbers[0] = 1
      numbers[1] = :gap unless numbers[1] == 2
      numbers[-2] = :gap unless numbers[-2] == pages - 1
      numbers[-1] = pages
      numbers
    end
  end
end
