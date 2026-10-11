# frozen_string_literal: true

module Organisations
  class PostReactionsController < Organisations::BaseController
    include ProjectController

    before_action :set_ticket
    before_action :set_post
    before_action :set_reaction, only: :destroy

    def create
      authorize @post, :react?

      emoji = params[:emoji].to_s
      return head :unprocessable_content unless PostReaction::EMOJIS.include?(emoji)

      now = Time.current
      PostReaction.insert_all(
        [{
          organisation_id: @current_organisation.id,
          post_id: @post.id,
          user_id: current_user.id,
          emoji: emoji,
          created_at: now,
          updated_at: now
        }],
        unique_by: 'index_post_reactions_on_post_user_emoji'
      )
      @reaction = @post.post_reactions.find_by!(user: current_user, emoji: emoji)
      _read, notifications = Posts::MarkRead.call(post: @post, user: current_user)
      broadcast_read_notifications(notifications)

      respond_with_reactions
    end

    def destroy
      authorize @post, :react?

      @reaction.destroy!
      respond_with_reactions
    end

    private

    def set_ticket
      @ticket = @project.tickets.find(params[:ticket_id])
    end

    def set_post
      @post = @ticket.posts.find(params[:post_id])
    end

    # Scoping through current_user makes another person's reaction undeletable
    # even when an otherwise valid reaction UUID is forged into the route.
    def set_reaction
      @reaction = @post.post_reactions.find_by!(id: params[:id], user: current_user)
    end

    def respond_with_reactions
      @post.post_reactions.reload

      respond_to do |format|
        format.turbo_stream { render turbo_stream: reaction_streams }
        format.html do
          redirect_to organisation_project_ticket_path(
            @current_organisation, @project, @ticket, anchor: "post_#{@post.id}"
          )
        end
      end
    end

    def reaction_streams
      refresh_ticket_notification_count

      [
        turbo_stream.replace_all(
          "[data-post-reactions-for='#{@post.id}']",
          partial: 'organisations/post_reactions/reactions',
          locals: {
            post: @post,
            current_user: current_user,
            current_organisation: @current_organisation,
            can_react: true,
            reactions: @post.post_reactions.includes(:user).to_a
          }
        ),
        turbo_stream.replace_all(
          "[data-ticket-unread-for='#{@ticket.id}']",
          partial: 'organisations/tickets/unread_indicator',
          locals: {
            ticket: @ticket,
            unread: @unread_notifications_per_ticket.fetch(@ticket.id, 0).positive?
          }
        )
      ]
    end

    def refresh_ticket_notification_count
      @unread_notifications_per_ticket = current_user.notifications
                                                     .channel_in_app
                                                     .unread
                                                     .where(notifiable: @ticket)
                                                     .group(:notifiable_id)
                                                     .count
    end

    def broadcast_read_notifications(notifications)
      notifications.each do |notification|
        Notifications::BroadcastService.new(notification).broadcast_update
      rescue StandardError => e
        Rails.logger.warn("Failed to broadcast reaction read for notification #{notification.id}: #{e.message}")
      end
    end
  end
end
