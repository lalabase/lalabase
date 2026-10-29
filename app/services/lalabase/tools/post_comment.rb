# frozen_string_literal: true

module Lalabase
  module Tools
    # Posts a comment (Post) on a ticket through Actors::SavePost, the write the web
    # form uses, so an MCP comment carries the same side effects: the post_added
    # activity, the notifications to the ticket's subscribers, the author's own
    # marks read, the embedding. Returns the created post as JSON.
    #
    # The body arrives as ActionText HTML (format html, the default, stored as
    # sent) or as literal text (format plain, MCP 0.11). The rule is
    # Posts::Comment's, shared with POST /api/v1/tickets/:ticket_id/posts (REST
    # R3a); format, encoding and emptiness of the body are checked before the
    # ticket lookup.
    #
    # Mutating (D3): blocked for a read-only PAT. Record-mode (D7): authorizes the
    # ticket (:show?) and the post (:create?) before saving, or the tripwire fires.
    class PostComment < Base
      # The refusal texts of this surface (Posts::Comment::REFUSALS), unchanged
      # since the tool's first answer.
      REFUSAL_TEXT = {
        format_not_string: 'format must be a string',
        format_unknown: "format must be #{Posts::Comment::FORMATS.join(' or ')}",
        body_invalid_utf8: 'body must be valid UTF-8',
        body_nul: 'body must not contain NUL bytes',
        body_empty: 'body is required'
      }.freeze

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
            format: { type: 'string', enum: Posts::Comment::FORMATS,
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
        return Result.invalid_input('ticket_id is required') if ticket_id.empty?
        return Result.invalid_input('invalid ticket_id format') unless ticket_id.match?(UUID_FORMAT)

        # A format only when given: absent is html, a given null is refused.
        comment = Posts::Comment.parse(body: args[:body], is_private: args[:is_private], **args.slice(:format))
        return Result.invalid_input(REFUSAL_TEXT.fetch(comment.refusal)) if comment.refused?

        # Inside the read scope: a ticket the caller may not read answers like a
        # missing one (Base.readable_tickets).
        ticket = readable_tickets(context, context.project.tickets).find_by(id: ticket_id)
        return Result.new(content: "No ticket found for #{ticket_id}.", citations: [], kind: :empty) if ticket.nil?

        # Two checks, mirroring Api::V1::PostsController: :show? proves the actor
        # may see the ticket at all (private-post visibility lives in that policy),
        # :create? proves write access. Either denial → tripwire-safe 'Not authorized.'.
        authorize!(context, ticket, :show?)
        post = comment.build(ticket: ticket, current_user: context.actor)
        authorize!(context, post, :create?)

        outcome = comment.save
        return Result.new(error: comment_failure(outcome)) unless outcome.success?

        json_result(serialize(post))
      end

      # No code, so refused: a model validation does not prove the input was
      # wrong, and create_ticket and create_time_session answer a refused save
      # the same way. An unexpected failure (BaseActor's :internal_error where it
      # does not re-raise) gets a fixed text: its message may name the database.
      # Only a failure before the commit gets here: a comment already written
      # counts as saved (Posts::Comment#save).
      def self.comment_failure(outcome)
        return 'comment failed: unexpected error' if outcome.code == :internal_error

        "comment failed: #{outcome.errors.join(', ')}"
      end
      private_class_method :comment_failure

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
