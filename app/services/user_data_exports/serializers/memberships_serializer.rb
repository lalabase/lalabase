# frozen_string_literal: true

module UserDataExports
  module Serializers
    # Membership rows joined with organisation + role names. Dedicated class
    # because Membership carries BOTH a legacy string column `role` and a
    # belongs_to :role (role_id) — the association shadows the column reader,
    # so the legacy value must be read via [] explicitly.
    class MembershipsSerializer
      # Audited contract: the secret guard checks THIS list, and the
      # serializer spec asserts emitted keys == ATTRIBUTES. When adding a key
      # to the hash below, add it here too — otherwise the spec goes red
      # (which is the point: no key ships unaudited).
      ATTRIBUTES = %w[organisation_name role_title legacy_role active created_at].freeze

      def self.call(_source, user)
        Membership.where(user: user).includes(:organisation).map do |membership|
          {
            'organisation_name' => membership.organisation&.name,
            'role_title' => membership_role_title(membership),
            'legacy_role' => membership[:role],
            'active' => membership.active,
            'created_at' => membership.created_at
          }
        end
      end

      # No includes(:role) in .call: Role is acts_as_tenant and this source
      # runs globally — preloading would raise NoTenantSet (require_tenant).
      # The role is read per membership inside ITS org's tenant instead; a
      # user has a handful of memberships, so the per-row query is bounded
      # (allow-listed in spec/support/prosopite.rb like the other intentional
      # per-tenant loops).
      def self.membership_role_title(membership)
        return if membership.role_id.blank? || membership.organisation.blank?

        ActsAsTenant.with_tenant(membership.organisation) { membership.role&.title }
      end
    end
  end
end
