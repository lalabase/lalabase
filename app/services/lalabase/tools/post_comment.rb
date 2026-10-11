# frozen_string_literal: true

module Lalabase
  module Tools
    # Posts a comment (Post) on a ticket through Actors::SavePost, the write the web
    # form uses, so an MCP comment carries the same side effects: the post_added
    # activity, the notifications to the ticket's subscribers, the author's own
    # marks read, the embedding. Returns the created post as JSON.
    #
    # The body arrives as ActionText HTML (format html, the default, stored as
    # sent) or as literal text (format plain, MCP 0.11): Posts::PlainTextBody
    # escapes it and turns line breaks into paragraphs and <br>, so body_text
    # comes back as the client sent it. Format, encoding and emptiness of the
    # body are checked before the ticket lookup.
    #
    # Mutating (D3): blocked for a read-only PAT. Record-mode (D7): authorizes the
    # ticket (:show?) and the post (:create?) before saving, or the tripwire fires.
    class PostComment < Base
      # The body formats a client may name, read by the schema and the check.
      FORMATS = %w[html plain].freeze
      DEFAULT_FORMAT = 'html'
      PLAIN_FORMAT = 'plain'

      # Writes on behalf of context.actor. No chat set may ever carry a mutating
      # tool, so the Runner's bar can never fire here — the declaration is kept
      # truthful anyway, so the registry guard stays a derived rule rather than a
      # hand-kept exception list.
      def self.requires_actor?
        true
      end

      def self.mutating?
        true
      end

      def self.authorization_mode
        :record
      end

      def self.tool_name
        'post_comment'
      end

      def self.description
        'Posts a comment on a ticket, identified by its UUID. Requires a body. ' \
          'Set is_private: true to make the comment visible only to you. Returns ' \
          'the created comment as JSON.'
      end

      def self.input_schema
        {
          type: 'object',
          properties: {
            ticket_id: { type: 'string', description: 'UUID of the ticket to comment on.' },
            body: { type: 'string', description: 'Comment body (required). HTML unless format is plain.' },
            format: { type: 'string', enum: FORMATS,
                      description: 'Body format: html (default) or plain. Plain escapes literal text, turns blank lines ' \
                                   'into paragraphs and single line breaks into <br>; line endings are normalized, ' \
                                   'blank lines at the edges are dropped, repeated spaces collapse in the web view, ' \
                                   'no Markdown.' },
            is_private: { type: 'boolean', description: 'If true, only you can see the comment.' }
          },
          required: %w[ticket_id body]
        }
      end

      def self.execute(args:, context:)
        return Result.new(error: 'project context missing') if context.project.nil?

        args = symbolized(args)
        ticket_id = args[:ticket_id].to_s.strip
        body = args[:body].to_s
        return Result.invalid_input('ticket_id is required') if ticket_id.empty?
        return Result.invalid_input('invalid ticket_id format') unless ticket_id.match?(UUID_FORMAT)

        format = args.fetch(:format, DEFAULT_FORMAT)
        return Result.invalid_input('format must be a string') unless format.is_a?(String)
        return Result.invalid_input("format must be #{FORMATS.join(' or ')}") unless FORMATS.include?(format)

        # The JSON parser lets invalid UTF-8 through inside a string, and
        # String#strip raises on it: refused for both formats before any string
        # method runs on the body.
        body = body.dup.force_encoding(Encoding::UTF_8)
        return Result.invalid_input('body must be valid UTF-8') unless body.valid_encoding?

        plain = format == PLAIN_FORMAT
        # plain promises body_text == body, so a byte that cannot round-trip is
        # refused rather than cleaned. html keeps its legacy behaviour: the HTML
        # parser drops a NUL byte on its own.
        return Result.invalid_input('body must not contain NUL bytes') if plain && body.include?("\0")

        # Decided on what would be stored: a plain body of Unicode whitespace
        # only converts to nothing (String#strip knows ASCII whitespace only).
        content = plain ? Posts::PlainTextBody.call(body: body) : body
        return Result.invalid_input('body is required') if content.strip.empty?

        # Inside the read scope: a ticket the caller may not read answers like a
        # missing one (Base.readable_tickets).
        ticket = readable_tickets(context, context.project.tickets).find_by(id: ticket_id)
        return Result.new(content: "No ticket found for #{ticket_id}.", citations: [], kind: :empty) if ticket.nil?

        # Two checks, mirroring Api::V1::PostsController: :show? proves the actor
        # may see the ticket at all (private-post visibility lives in that policy),
        # :create? proves write access. Either denial → tripwire-safe 'Not authorized.'.
        authorize!(context, ticket, :show?)
        # The record exists before #call, so the policy sees the post it is asked
        # about (PostUpdateService does the same).
        actor = Actors::SavePost.new(ticket: ticket, current_user: context.actor,
                                     params: { content: content, is_private: [true, 'true'].include?(args[:is_private]) })
        authorize!(context, actor.record, :create?)

        # No code, so refused: a model validation does not prove the input was wrong,
        # and create_ticket and create_time_session answer a refused save the same way.
        outcome = actor.call
        return Result.new(error: "comment failed: #{outcome.errors.join(', ')}") unless outcome.success?

        json_result(serialize(actor.record))
      end

      def self.serialize(post)
        {
          id: post.id,
          ticket_id: post.ticket_id,
          author: { id: post.user_id, name: post.user&.display_name },
          body_text: post.plain_text_version,
          is_private: post.is_private?,
          created_at: post.created_at.iso8601
        }
      end
      private_class_method :serialize
    end
  end
end
