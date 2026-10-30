# frozen_string_literal: true

# The ticket view in pages, one rule for two surfaces (cli_rest_plan D5): the
# MCP get_ticket tool and GET /api/v1/tickets/:id (plus the number route and
# GET /api/v1/tickets/:ticket_id/posts/:id) parse the same options and build
# the same pages. Each surface keeps its own envelope: the MCP caps (body
# lengths, attachment text, assistant limits, citations) stay in the tool, the
# REST controllers hand the pages out uncut.
#
# Visibility is the serializer's: every page and count comes out of
# ticket.posts.readable_by, so posts_total never counts a comment the reader
# may not see. The attachments are the ticket's OWN files (TicketDocument);
# files on comments are not part of this list, each comment lists its own
# (Tickets::Serializer#post_attachments, REST R7).
#
# Entry point: options
module Tickets
  class Reading
    MAX_POSTS = 50
    MAX_ATTACHMENTS = 10
    # Far beyond any real ticket, close enough to keep the OFFSET in range
    # (the same reasoning as Notifications::InboxQuery::MAX_PAGE).
    MAX_PAGE = 100_000
    POST_ORDERS = %w[oldest newest].freeze
    # Any one of these switches the REST answer to pages.
    PAGING_KEYS = %w[posts_page posts_per_page posts_order attachments_page].freeze

    Options = Struct.new(:posts_page, :posts_per_page, :newest, :attachments_page, keyword_init: true)
    class InvalidOption < ArgumentError; end

    # Strict like Notifications::InboxQuery: a value that cannot be read is
    # refused, never quietly replaced by a default. Only a posts_per_page above
    # MAX_POSTS differs by surface: MCP has always clamped it (`over_max:
    # :clamp`), REST refuses it (`:refuse`).
    #
    # @param args [Hash] symbol keys posts_page, posts_per_page, posts_order, attachments_page
    # @raise [InvalidOption] with a message naming the argument
    def self.options(args, over_max: :clamp)
      Options.new(
        posts_page: page_arg(args[:posts_page], 'posts_page'),
        posts_per_page: per_page_arg(args[:posts_per_page], over_max),
        newest: order_arg(args[:posts_order]),
        attachments_page: page_arg(args[:attachments_page], 'attachments_page')
      )
    end

    # @param params [#key?] request parameters
    def self.paging_requested?(params)
      PAGING_KEYS.any? { |key| params.key?(key) }
    end

    def initialize(serializer:)
      @serializer = serializer
    end

    # One page out of the reader's readable comments; posts_total is their count,
    # posts_truncated says the page is a part of them.
    def post_page(ticket, options)
      per_page = options.posts_per_page
      entries, total = @serializer.posts_page(ticket, page: options.posts_page, per_page: per_page,
                                                      newest: options.newest)
      {
        posts: entries,
        posts_total: total,
        posts_truncated: total > entries.size,
        posts_page: options.posts_page,
        posts_per_page: per_page,
        posts_pages: (total + per_page - 1) / per_page,
        posts_order: options.newest ? 'newest' : 'oldest'
      }
    end

    # One comment the reader may read on THIS ticket, or nil: hidden, foreign and
    # missing comments read alike.
    def post(ticket, id)
      @serializer.readable_post(ticket, id)
    end

    # The comment of `id` as a page of one, with the count of readable comments,
    # or nil like #post.
    def one_post(ticket, id)
      entry = post(ticket, id)
      return nil if entry.nil?

      total = @serializer.readable_posts_count(ticket)
      { posts: [entry], posts_total: total, posts_truncated: total > 1 }
    end

    # A page of MAX_ATTACHMENTS, bounded IN the query; attachments_total is the
    # separate COUNT, attachments_truncated says the page is a part: a list that
    # was silently cut is a list a reader takes as complete.
    def attachment_page(ticket, page)
      files = @serializer.attachments(ticket, limit: MAX_ATTACHMENTS, offset: (page - 1) * MAX_ATTACHMENTS)
      total = @serializer.attachments_total(ticket)
      {
        attachments: files,
        attachments_total: total,
        attachments_truncated: total > files.size,
        attachments_page: page,
        attachments_pages: (total + MAX_ATTACHMENTS - 1) / MAX_ATTACHMENTS
      }
    end

    def self.integer_arg(value, name)
      return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)
      return value if value.is_a?(Integer)

      (value.is_a?(String) && Integer(value.strip, 10, exception: false)) ||
        raise(InvalidOption, "invalid #{name} #{value.inspect} (expected a whole number)")
    end
    private_class_method :integer_arg

    def self.page_arg(value, name)
      number = integer_arg(value, name)
      return 1 if number.nil?
      return number if number.between?(1, MAX_PAGE)

      raise InvalidOption, "invalid #{name} #{value.inspect} (1 to #{MAX_PAGE})"
    end
    private_class_method :page_arg

    def self.per_page_arg(value, over_max)
      number = integer_arg(value, 'posts_per_page')
      return MAX_POSTS if number.nil?
      raise InvalidOption, "invalid posts_per_page #{value.inspect} (at least 1)" if number < 1
      return number if number <= MAX_POSTS
      return MAX_POSTS if over_max == :clamp

      raise InvalidOption, "invalid posts_per_page #{value.inspect} (1 to #{MAX_POSTS})"
    end
    private_class_method :per_page_arg

    def self.order_arg(value)
      raw = value.to_s.strip
      return false if raw.empty?
      raise InvalidOption, "invalid posts_order #{value.inspect} (oldest or newest)" unless POST_ORDERS.include?(raw)

      raw == 'newest'
    end
    private_class_method :order_arg
  end
end
