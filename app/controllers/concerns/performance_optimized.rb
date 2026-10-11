# frozen_string_literal: true

module PerformanceOptimized
  extend ActiveSupport::Concern

  included do
    # Helper to cache policy checks at request level
    def cached_policy(record)
      @policy_cache ||= {}
      cache_key = "#{record.class.name}_#{record.id}"

      @policy_cache[cache_key] ||= policy(record)
    end

    # Helper to cache user permissions at request level
    def cached_user_permission?(permission, area = nil)
      @permission_cache ||= {}
      cache_key = "#{permission}_#{area}"

      @permission_cache[cache_key] ||= if area
                                         current_user.has_permission_in_organisation?(current_organisation, permission, area)
                                       else
                                         current_user.account_admin_in?(current_organisation)
                                       end
    end

    # Helper to preload associations in batches
    def batch_preload(records, *associations)
      ActiveRecord::Associations::Preloader.new(
        records: records,
        associations: associations
      ).call
      records
    end
  end
end
