# frozen_string_literal: true

# The one rule of a comment written through a token: the MCP tool post_comment
# and POST /api/v1/tickets/:ticket_id/posts both write through it, so the two
# surfaces cannot drift apart again (before REST R3a, REST took every body as
# HTML and checked neither its encoding nor NUL bytes).
#
# Entry point: parse
#
# Three steps, because the callers authorize in between (cut like
# TimeSessions::Booking): `parse` checks the format and the body and converts
# a plain body, `build` makes the unsaved post on a ticket the caller has found
# readable, through Actors::SavePost (the web form's write: the post_added
# activity, the notifications, the author's read marks, the embedding), and
# `save` writes it once the caller has authorized the post (:create?). Rights
# stay with the callers; this object holds none.
#
# The body arrives as ActionText HTML (format html, the default, stored as
# sent) or as literal text (format plain): Posts::PlainTextBody escapes it and
# turns line breaks into paragraphs and <br>, so body_text comes back as the
# client sent it. A body that is no string is taken as its text (`to_s`), as
# both surfaces always did.
module Posts
  class Comment
    # The body formats a client may name.
    FORMATS = %w[html plain].freeze
    DEFAULT_FORMAT = 'html'
    PLAIN_FORMAT = 'plain'

    # Why `parse` turns a comment away, in the order it checks. Each caller
    # words it for its surface.
    REFUSALS = %i[format_not_string format_unknown body_invalid_utf8 body_nul body_empty].freeze

    attr_reader :refusal

    # `format` absent is html; given, it must be one of FORMATS as a String.
    def self.parse(body:, format: DEFAULT_FORMAT, is_private: nil, visible_to_user_id: nil)
      new(body: body, format: format, is_private: is_private, visible_to_user_id: visible_to_user_id)
    end

    def initialize(body:, format:, is_private:, visible_to_user_id:)
      @format = format
      @attributes = { is_private: [true, 'true'].include?(is_private), visible_to_user_id: visible_to_user_id }
      @refusal = refusal_for(body.to_s)
    end

    def refused?
      !@refusal.nil?
    end

    def plain?
      @format == PLAIN_FORMAT
    end

    # The unsaved post on `ticket`, for the caller's :create? check: the actor
    # builds it before it saves, so the policy sees the post it is asked about.
    # An empty body can be built, the model refuses it on save; a body the rule
    # could not read (format, encoding, NUL) cannot.
    def build(ticket:, current_user:)
      raise ArgumentError, "unreadable comment: #{@refusal}" if @content.nil?

      @actor = Actors::SavePost.new(ticket: ticket, current_user: current_user,
                                    params: { content: @content, **@attributes })
      @actor.record
    end

    # => Actors::BaseActor::Result. A model refusal (an empty content, an
    # addressee outside the organisation) comes back as :validation_failed,
    # nothing written.
    def save
      raise ArgumentError, 'build the comment before saving it' if @actor.nil?

      @actor.call
    end

    private

    def refusal_for(body)
      return :format_not_string unless @format.is_a?(String)
      return :format_unknown unless FORMATS.include?(@format)

      # The JSON parser lets invalid UTF-8 through inside a string, and
      # String#strip raises on it: refused for both formats before any string
      # method runs on the body.
      body = readable(body)
      return :body_invalid_utf8 unless body&.valid_encoding?

      # plain promises body_text == body, so a byte that cannot round-trip is
      # refused rather than cleaned. html keeps its legacy behaviour: the HTML
      # parser drops a NUL byte on its own.
      return :body_nul if plain? && body.include?("\0")

      # Decided on what would be stored: a plain body of Unicode whitespace
      # only converts to nothing (String#strip knows ASCII whitespace only).
      @content = plain? ? Posts::PlainTextBody.call(body: body) : body
      :body_empty if @content.strip.empty?
    end

    # The body in the encoding the rule reads it in, nil when it has none.
    # JSON and forms give UTF-8 on both surfaces. Only a multipart part (REST)
    # can name a charset of its own: html, stored as sent, keeps it, and
    # ActionText reads it as it always did (a Latin-1 comment keeps its
    # letters); plain transcodes it. A binary part names no charset, so plain
    # reads its bytes as UTF-8.
    def readable(body)
      return body.dup.force_encoding(Encoding::UTF_8) if body.encoding == Encoding::UTF_8
      return body unless plain?
      return body.dup.force_encoding(Encoding::UTF_8) if body.encoding == Encoding::BINARY

      body.encode(Encoding::UTF_8)
    rescue EncodingError
      nil
    end
  end
end
