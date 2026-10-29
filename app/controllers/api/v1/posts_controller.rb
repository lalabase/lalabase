# frozen_string_literal: true

module Api
  module V1
    class PostsController < BaseController
      include Api::V1::ReadableTicket

      idempotent :create

      # POST /api/v1/tickets/:ticket_id/posts
      #
      # Writes by the rule the MCP tool post_comment writes by (Posts::Comment,
      # REST R3a): post[format] html, the default, stores the body as sent;
      # plain stores literal text, escaped. The write is the web form's
      # (Actors::SavePost), so an API comment carries the same side effects: the
      # post_added activity, the notifications, the author's marks read, the
      # embedding. The input is checked inside the read gate, so a refusal of it
      # only ever answers for a ticket the token can read.
      def create
        with_readable_ticket(params[:ticket_id]) do |ticket|
          comment = Posts::Comment.parse(**comment_input)
          next render_comment_refusal(comment.refusal) if refused_here?(comment)

          post = comment.build(ticket: ticket, current_user: current_user)
          authorize post, :create?

          result = comment.save
          if result.success?
            render json: { data: serialize(post) }, status: :created
          else
            render_comment_failure(result)
          end
        end
      end

      private

      # Without format (and with html) an empty body stays the model's refusal,
      # answered after the write check with every message the model has: the
      # answer this endpoint gave before R3a, which existing callers read. A
      # plain body that converts to nothing is the rule's refusal.
      def refused_here?(comment)
        comment.refused? && (comment.plain? || comment.refusal != :body_empty)
      end

      def render_comment_refusal(refusal)
        render_error(error: 'validation_failed', errors: [I18n.t("services.post_comment.#{refusal}")],
                     status: :unprocessable_entity)
      end

      # A failure the actor did not expect (BaseActor answers :internal_error
      # where it does not re-raise) is no refusal of the input: a 500 without the
      # exception's text, which may name the database. Every other failure
      # answers as it always did.
      def render_comment_failure(result)
        return render_error(error: 'internal_error', status: :internal_server_error) if result.code == :internal_error

        render_error(error: 'validation_failed', errors: result.errors, status: :unprocessable_entity)
      end

      # The format goes to the rule raw, not through permit: strong parameters
      # drop a list or an object, which would have written the comment as html.
      # Given, it goes as it came (null included); absent, it is html. It is
      # permitted all the same, so a plain comment logs no unpermitted parameter.
      def comment_input
        input = params.require(:post)
        # A post that is no object (post=text) answers like a missing one.
        raise ActionController::ParameterMissing, :post unless input.is_a?(ActionController::Parameters)

        permitted = input.permit(:body, :format, :is_private, :visible_to_user_id)
        fields = { body: permitted[:body], is_private: permitted[:is_private],
                   visible_to_user_id: permitted[:visible_to_user_id] }
        fields[:format] = input[:format] if input.key?(:format)
        fields
      end

      def serialize(post)
        {
          id: post.id,
          ticket_id: post.ticket_id,
          author: { id: post.user_id, name: post.user&.display_name },
          body_html: post.content&.body&.to_html,
          body_text: post.plain_text_version,
          is_private: post.is_private?,
          visible_to_user_id: post.visible_to_user_id,
          created_at: post.created_at.iso8601,
          updated_at: post.updated_at.iso8601
        }
      end
    end
  end
end
