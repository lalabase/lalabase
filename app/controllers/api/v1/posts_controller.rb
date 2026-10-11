# frozen_string_literal: true

module Api
  module V1
    class PostsController < BaseController
      include Api::V1::ReadableTicket

      # POST /api/v1/tickets/:ticket_id/posts
      #
      # The web form's write (Actors::SavePost), so an API comment carries the same
      # side effects: the post_added activity, the notifications, the author's marks
      # read, the embedding. The record exists before #call for the policy.
      def create
        with_readable_ticket(params[:ticket_id]) do |ticket|
          actor = Actors::SavePost.new(ticket: ticket, current_user: current_user, params: post_attributes)
          authorize actor.record, :create?

          result = actor.call
          if result.success?
            render json: { data: serialize(actor.record) }, status: :created
          else
            render json: { error: 'validation_failed', errors: result.errors },
                   status: :unprocessable_entity
          end
        end
      end

      private

      def post_attributes
        attributes = { is_private: [true, 'true'].include?(post_params[:is_private]),
                       visible_to_user_id: post_params[:visible_to_user_id] }
        attributes[:content] = post_params[:body] if post_params[:body].present?
        attributes
      end

      def post_params
        params.require(:post).permit(:body, :is_private, :visible_to_user_id)
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
