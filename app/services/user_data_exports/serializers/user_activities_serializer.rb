# frozen_string_literal: true

module UserDataExports
  module Serializers
    # Security/audit history (logins, password resets, …). Dedicated class
    # because attribute_changes must be FILTERED: the raw JSONB can carry
    # third-party context (e.g. admin-driven role changes), so only the user's
    # own identity fields pass the whitelist.
    class UserActivitiesSerializer
      # Audited contract: the secret guard checks THIS list, and the
      # serializer spec asserts emitted keys == ATTRIBUTES. When adding a key
      # to the hash below, add it here too — otherwise the spec goes red
      # (which is the point: no key ships unaudited).
      ATTRIBUTES = %w[action category status ip_address user_agent organisation_name
                      created_at changes].freeze

      # Own identity fields only — never the raw attribute_changes JSONB.
      SAFE_CHANGE_KEYS = %w[email old_email new_email first_name last_name
                            language_preference timezone].freeze

      def self.call(_source, user)
        rows = []
        UserActivity.where(user: user).includes(:organisation).find_each(batch_size: 500) do |activity|
          rows << {
            'action' => activity.action,
            'category' => activity.category,
            'status' => activity.status,
            'ip_address' => activity.ip_address,
            'user_agent' => activity.user_agent,
            'organisation_name' => activity.organisation&.name,
            'created_at' => activity.created_at,
            'changes' => (activity.attribute_changes || {}).slice(*SAFE_CHANGE_KEYS)
          }
        end
        rows
      end
    end
  end
end
