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
#   A size a REQUEST names (`?items=`) is read by .size, the one reading of every
#   list: no number, below 1, a list or a hash names no size, and the caller's
#   default and ceiling apply.
#
# Numbers given as text are decimal: '010' is ten. Kernel#Integer alone reads a
# leading 0 as octal and 0x as hex, and '08' would raise.
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

    # A page size as it arrives in a request. => Integer of at least 1, at most
    # `max`; `default` (nil without one) when the value names none: absent, blank,
    # no number, below 1, or a list or a hash (`?items[]=20`), on which `#to_i`
    # raises. The default is capped as well.
    def self.size(value, default: nil, max: nil)
      number =
        case value
        when Integer then value
        when String then value.to_i
        end
      number = default unless number&.positive?
      max && number ? [number, max].min : number
    end

    def initialize(count:, page:, limit:, past_end: :empty)
      raise ArgumentError, "past_end is :empty or :last, got #{past_end.inspect}" unless PAST_END.include?(past_end)

      @limit = whole_number(limit)
      raise ArgumentError, "limit must be a whole number of at least 1, got #{limit.inspect}" unless @limit&.positive?

      total = whole_number(count)
      raise ArgumentError, "count must be a whole number, got #{count.inspect}" unless total

      @count = [total, 0].max
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

    # Whether a bar has a link to show: more than one page, or a page behind the
    # end, which links back to the last one even when the list has a single page.
    # Every bar asks this, never `pages > 1`.
    def links?
      !(prev.nil? && self.next.nil?)
    end

    # The same list, another page.
    def with_page(number)
      self.class.new(count: count, page: number, limit: limit, past_end: @past_end)
    end

    # The links of a full bar: Integers for pages, the current page as a String,
    # :gap where pages are left out. With 30 pages on page 12:
    #   [1, :gap, 10, 11, "12", 13, 14, 15, :gap, 30]
    # (ten consecutive pages, 8 to 17, four before the current one; the first and
    # the last two give way to the ends and the gaps).
    # Past the end the bar is the last page's, and no link is the current one.
    def series(size: SERIES_SIZE)
      numbers = size >= pages ? (1..pages).to_a : window(size)
      numbers.map { |number| number == page ? number.to_s : number }
    end

    # The JSON answers of the saved views (`pagination`) serialised the gem's
    # object until 18.11.2026. Its numbers keep their names there: `last` (the
    # number of pages), `in` (rows on this page) and `offset`. Its settings
    # (`vars`, `outset`) do not: they held the request's parameters.
    def as_json(*)
      {
        count: count, page: page, limit: limit, pages: pages, last: pages, in: rows_on_page,
        offset: offset, prev: prev, next: self.next, from: from, to: to
      }
    end

    # How many rows this page holds: none on an empty list or behind the end.
    def rows_on_page
      from.zero? ? 0 : to - from + 1
    end

    private

    # => Integer, or nil for what is no whole number. Text is decimal.
    def whole_number(value)
      value.is_a?(String) ? Integer(value, 10, exception: false) : Integer(value, exception: false)
    end

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
