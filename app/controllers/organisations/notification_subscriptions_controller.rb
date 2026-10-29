# frozen_string_literal: true

module Organisations
  class NotificationSubscriptionsController < BaseController
    before_action :load_subscribable
    before_action :load_subscription, only: [:destroy]
    before_action :authorize_access

    # POST /organisations/:id/tickets/:ticket_id/subscription/toggle
    # POST /organisations/:id/projects/:project_id/subscription/toggle
    def toggle
      @subscription = NotificationSubscription.toggle_for(
        user: current_user,
        item: @subscribable,
        mode: params[:mode]
      )

      respond_to do |format|
        format.turbo_stream { render_subscriber_list_response }
        format.html { redirect_back_with_notice }
      end
    end

    # POST /organisations/:id/tickets/:ticket_id/subscription
    # POST /organisations/:id/projects/:project_id/subscription
    def create
      @subscription = NotificationSubscription.find_or_initialize_for(
        user: current_user,
        item: @subscribable
      )

      @subscription.mode = params[:mode] || 'follow'

      if @subscription.save
        respond_to do |format|
          format.turbo_stream { render_subscriber_list_response }
          format.html { redirect_back_with_notice('Now following') }
        end
      else
        respond_to do |format|
          format.turbo_stream { render_error_response }
          format.html { redirect_back_with_alert(@subscription.errors.full_messages.join(', ')) }
        end
      end
    end

    # DELETE /organisations/:id/tickets/:ticket_id/subscription
    # DELETE /organisations/:id/projects/:project_id/subscription
    def destroy
      @subscription.destroy

      respond_to do |format|
        format.turbo_stream { render_subscriber_list_response }
        format.html { redirect_back_with_notice('Unsubscribed') }
      end
    end

    # POST /organisations/:id/tickets/:ticket_id/subscription/subscribe_other
    def subscribe_other
      authorize @subscribable, :update?

      target_user = @current_organisation.users.find(params[:user_id])

      @subscription = NotificationSubscription.subscribe_other(
        user: target_user,
        item: @subscribable,
        subscribed_by: current_user
      )

      @subscribable.track_subscriber_added(target_user) if @subscribable.respond_to?(:track_subscriber_added)

      respond_to do |format|
        format.turbo_stream { render_subscriber_list_response }
        format.html { redirect_back_with_notice }
      end
    end

    # DELETE /organisations/:id/tickets/:ticket_id/subscription/unsubscribe_other
    def unsubscribe_other
      @target_subscription = @subscribable.notification_subscriptions
                                          .find(params[:subscription_id])

      authorize @subscribable, :update?

      # Only manual subscriptions can be revoked. System-/self-subscriptions
      # are managed by their own lifecycle (e.g. assignee changes).
      unless @target_subscription.source == NotificationSubscription::SOURCE_MANUAL
        respond_to do |format|
          format.turbo_stream { head :unprocessable_entity }
          format.html { redirect_back fallback_location: root_path, alert: t('shared.errors.not_authorized') }
        end
        return
      end

      target_user = @target_subscription.user
      @target_subscription.destroy

      @subscribable.track_subscriber_removed(target_user) if @subscribable.respond_to?(:track_subscriber_removed)

      respond_to do |format|
        format.turbo_stream { render_subscriber_list_response }
        format.html { redirect_back_with_notice }
      end
    end

    # GET /organisations/:id/tickets/:ticket_id/subscription/available_users
    def available_users
      # Only offer people with access to the subscribable's project — otherwise
      # the autocomplete leaks names/emails of people from foreign projects.
      # Project#assignable_users: the canonical inverse (incl. org admins/global
      # roles) among ACTIVE members, the people subscribe_other accepts (cf.
      # Neo::SubscriberListComponent).
      accessible = subscribable_project.assignable_users
      subscribed_user_ids = @subscribable.notification_subscriptions.pluck(:user_id)
      users = accessible.where.not(id: subscribed_user_ids)

      if params[:q].present?
        query = "%#{User.sanitize_sql_like(params[:q].downcase)}%"
        # Names, and the email each member shows to others (User::EmailDisplay):
        # a hidden login address is never matched, so the picker cannot confirm it.
        by_name = users.where('LOWER(first_name) LIKE :q OR LOWER(last_name) LIKE :q', q: query)
        users = by_name.or(users.merge(User.matching_shown_email(params[:q])))
      end

      render json: users.limit(20).map { |u| { id: u.id, name: u.display_name, email: u.shown_email } }
    end

    private

    def load_subscribable
      if params[:ticket_id]
        @subscribable = @current_organisation.tickets
                                             .joins(:project)
                                             .find(params[:ticket_id])
      elsif params[:project_id]
        @subscribable = @current_organisation.projects.find(params[:project_id])
      else
        raise ActiveRecord::RecordNotFound
      end
    end

    # The project whose access circle determines the offerable people — regardless of
    # whether a ticket or a project directly is being subscribed to.
    def subscribable_project
      @subscribable.is_a?(Project) ? @subscribable : @subscribable.project
    end

    def load_subscription
      @subscription = current_user.notification_subscriptions
                                  .for_item(@subscribable)
                                  .first!
    rescue ActiveRecord::RecordNotFound
      redirect_back_with_alert('Not subscribed to this item')
    end

    def authorize_access
      # Check if user has view access to the subscribable item
      case @subscribable
      when Ticket
        authorize @subscribable.project, :show?
      when Project
        authorize @subscribable, :show?
      else
        raise Pundit::NotAuthorizedError
      end
    end

    def render_subscriber_list_response
      mode = params[:subscriber_mode].presence || 'full_inline'
      # subscriber_open keeps the in-place checkbox editor open across the
      # replace - every checkbox form sends it, so a toggle does not slam
      # the editor shut under the pointer.
      open = params[:subscriber_open].present?
      component = Neo::SubscriberListComponent.new(
        item: @subscribable, current_user: current_user, mode: mode, open: open
      )
      render turbo_stream: turbo_stream.replace(component.dom_id, component)
    end

    def render_error_response
      render turbo_stream: turbo_stream.replace(
        'flash',
        partial: 'shared/flash',
        locals: { alert: @subscription.errors.full_messages.join(', ') }
      )
    end

    def redirect_back_with_notice(message = 'Subscription updated')
      redirect_back(
        fallback_location: organisation_root_path(@current_organisation),
        notice: message
      )
    end

    def redirect_back_with_alert(message)
      redirect_back(
        fallback_location: organisation_root_path(@current_organisation),
        alert: message
      )
    end
  end
end
