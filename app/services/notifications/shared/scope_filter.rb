# frozen_string_literal: true

module Notifications
  module Shared
    # The NotificationScopeFilter standardizes user/organisation filtering
    # for all notification services.
    #
    # PURPOSE:
    # Every service needs user- and organisation-based filtering.
    # This filter provides unified, safe scoping methods.
    #
    # WHY BUILT THIS WAY:
    # - DRY Principle: Eliminates @user/@organisation duplication
    # - Security: Consistent tenant-safe filtering
    # - Performance: Optimized queries with proper includes
    # - Maintainability: Central place for scoping logic
    #
    # EXAMPLE:
    # filter = Notifications::Shared::ScopeFilter.new(user, organisation)
    # notifications = filter.user_notifications.email_channel.recent

    class ScopeFilter
      attr_reader :user, :organisation

      def initialize(user, organisation = nil)
        @user = user
        @organisation = organisation || user.organisations.first
      end

      # Base scopes - building blocks for all services

      def user_notifications
        @user.notifications.where(organisation: @organisation)
      end

      def organisation_notifications
        ActsAsTenant.with_tenant(@organisation) do
          Notification.all
        end
      end

      def scoped_email_logs
        ActsAsTenant.with_tenant(@organisation) do
          EmailLog.all
        end
      end

      # Commonly used filtered scopes

      def email_notifications
        user_notifications.channel_email
      end

      def pending_notifications
        user_notifications.where(state: %w[queued sent])
      end

      def immediate_delivery_notifications
        email_notifications.where(state: %w[queued sent]).joins(
          # Join with preference resolution for immediate delivery
          <<~SQL
            LEFT JOIN notification_preferences np ON (
              np.user_id = '#{@user.id}' AND
              np.event_type = notifications.event_type AND
              np.channel = 'email' AND
              np.frequency = 'immediate' AND
              np.enabled = true
            )
          SQL
        ).where.not(np: { id: nil })
      end

      # Performance optimized scopes with includes

      def with_associations
        user_notifications.includes(:actor, :notifiable, :organisation)
      end

      def with_email_logs
        user_notifications.includes(:email_logs)
      end

      def with_full_context
        user_notifications.includes(:actor, :notifiable, :organisation, :email_logs)
      end

      # Service-specific convenience methods

      def for_fanout_service(&block)
        # Used by fanout service to create new notifications
        with_tenant_context(&block)
      end

      def for_suppression_check
        # Used by suppressor service
        with_associations.recent
      end

      # Execution context helpers

      def with_tenant_context(&block)
        ActsAsTenant.with_tenant(@organisation, &block)
      end

      def execute_scoped(scope_method)
        scope = send(scope_method)
        with_tenant_context do
          yield(scope) if block_given?
        end
      end

      # Debugging and introspection

      def scope_summary
        with_tenant_context do
          {
            user_id: @user.id,
            organisation_id: @organisation&.id,
            organisation_name: @organisation&.name,
            total_notifications: user_notifications.count,
            email_notifications: email_notifications.count,
            pending_notifications: pending_notifications.count,
            recent_notifications: user_notifications.where('created_at > ?', 24.hours.ago).count
          }
        end
      end

      # Validation helpers

      def valid_user_organisation_combo?
        return false unless @user && @organisation

        @user.organisations.include?(@organisation)
      end

      def has_access_to_organisation?
        return true unless @organisation

        @user.organisations.exists?(@organisation.id)
      end

      private

      def recent
        user_notifications.where('created_at > ?', 24.hours.ago)
      end
    end
  end
end
