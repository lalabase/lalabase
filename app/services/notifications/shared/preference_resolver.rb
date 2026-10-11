# frozen_string_literal: true

module Notifications
  module Shared
    # The NotificationPreferenceResolver centralizes and optimizes the
    # resolution of NotificationPreferences for all services.
    #
    # PURPOSE:
    # Instead of every service calling NotificationPreference.resolve_for individually,
    # this resolver provides a unified, optimized API with caching.
    #
    # WHY BUILT THIS WAY:
    # - DRY Principle: Eliminates duplication across 5+ services
    # - Performance: Request-level caching prevents redundant DB calls
    # - Consistency: Unified preference resolution everywhere
    # - Maintainability: Central place for preference-logic changes
    #
    # EXAMPLE:
    # resolver = Notifications::Shared::PreferenceResolver.new(user, organisation)
    # pref = resolver.resolve(event_type: 'mention', channel: :email, scope: ticket)
    # # Subsequent calls with the same params use the cache

    class PreferenceResolver
      attr_reader :user, :organisation

      def initialize(user, organisation = nil)
        @user = user
        @organisation = organisation || user.organisations.first
        @cache = {}
      end

      # Main method: Resolve preference with caching
      def resolve(event_type:, channel:, scope: nil)
        cache_key = build_cache_key(event_type, channel, scope)

        unless @cache.key?(cache_key)
          @cache[cache_key] = NotificationPreference.resolve_for(
            user: @user,
            event_type: event_type,
            channel: channel,
            scope: scope
          )
        end
        @cache[cache_key]
      end

      # True batch query: loads all relevant preferences in ONE query,
      # then resolves hierarchically in-memory per notification.
      def batch_resolve(notifications, channel: :email)
        return {} if notifications.empty?

        # 1. Collect all unique event_types needed
        event_types = notifications.map(&:event_type).uniq

        # 2. ONE query for all preferences matching user + event_types + channel
        all_preferences = NotificationPreference
                          .where(user: @user, event_type: event_types, channel: channel)
                          .to_a

        # 3. Build index for fast in-memory lookup: [event_type, scope_type, scope_id, organisation_id]
        pref_index = {}
        all_preferences.each do |pref|
          index_key = [pref.event_type, pref.scope_type, pref.scope_id, pref.organisation_id]
          pref_index[index_key] = pref
        end

        # 4. Resolve hierarchically in-memory per notification
        result = {}
        notifications.each do |notification|
          cache_key = build_cache_key(notification.event_type, channel, notification.notifiable)

          unless @cache.key?(cache_key)
            @cache[cache_key] = resolve_from_index(
              pref_index, notification.event_type, channel, notification.notifiable
            )
          end

          result[notification.id] = @cache[cache_key]
        end

        result
      end

      # Convenience methods for common patterns

      # NOTE: should_suppress? is the exact logical negation of should_send_immediately?
      # (De Morgan's law: !(a && !b) == !a || b). Consider removing one if this class
      # is actively used in the future.
      def should_send_immediately?(event_type:, channel:, scope: nil)
        preference = resolve(event_type: event_type, channel: channel, scope: scope)
        preference.enabled? && !preference.frequency_never?
      end

      def should_suppress?(event_type:, channel:, scope: nil)
        preference = resolve(event_type: event_type, channel: channel, scope: scope)
        !preference.enabled? || preference.frequency_never?
      end

      # Clear cache (useful for testing or long-running processes)
      def clear_cache!
        @cache.clear
      end

      # Get cache stats for debugging
      def cache_stats
        {
          size: @cache.size,
          keys: @cache.keys
        }
      end

      private

      # In-memory hierarchical resolution from pre-loaded preferences:
      # 1. Item-level → 2. Project-level → 3. Org-level → 4. Global → 5. Default
      def resolve_from_index(pref_index, event_type, channel, scope)
        if scope
          # 1. Item-level
          found = pref_index[[event_type, scope.class.name, scope.id, nil]]
          return found if found

          # 2. Project-level
          if scope.respond_to?(:project) && scope.project
            found = pref_index[[event_type, 'Project', scope.project_id, nil]]
            return found if found
          end

          # 3. Org-level (from scope's organisation)
          if scope.respond_to?(:organisation) && scope.organisation
            found = pref_index[[event_type, nil, nil, scope.organisation.id]]
            return found if found
          end
        end

        # 3b. Org-level (from current tenant)
        current_org = if scope.respond_to?(:organisation)
                        scope.organisation
                      else
                        ActsAsTenant.current_tenant
                      end
        if current_org
          found = pref_index[[event_type, nil, nil, current_org.id]]
          return found if found
        end

        # 4. Global
        found = pref_index[[event_type, nil, nil, nil]]
        return found if found

        # 5. Default
        NotificationPreference.create_default_for(
          user: @user,
          event_type: event_type,
          channel: channel
        )
      end

      def build_cache_key(event_type, channel, scope)
        scope_key = scope ? "#{scope.class.name}:#{scope.id}" : 'nil'
        "#{@user.id}:#{@organisation&.id}:#{event_type}:#{channel}:#{scope_key}"
      end
    end
  end
end
