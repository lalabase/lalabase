# frozen_string_literal: true

# app/services/actors/save_role.rb
#
# Tier-1 actor: updates a role's own attributes AND syncs its permissions in one transaction,
# so a failing permission rolls the role-attribute change back too. Used by
# Organisations::RolesController#update. Reuses RolePermissionSync for the permission half.
module Actors
  class SaveRole < BaseActor
    def initialize(role:, role_params:, permissions:, current_user:)
      super()
      @role = role
      @role_params = role_params
      @permissions = permissions
      @current_user = current_user
    end

    def record
      @role
    end

    def perform
      refuse_rights_beyond_reach!
      @role.update!(@role_params)
      RolePermissionSync.call(role: @role, permissions: @permissions)
    end

    private

    # Every right the form actually CHANGES (granted or removed) must be one the
    # editor may change (RolePolicy#change_permission?). A submitted value equal
    # to the stored one is no change, so a full form round trip from a manager
    # passes as long as they only touch their own rights.
    def refuse_rights_beyond_reach!
      policy = RolePolicy.new(@current_user, @role)
      @permissions.each do |category, actions|
        actions.each do |action, value|
          next if (value == '1') == @role.has_permission?(category, action)
          next if policy.change_permission?(category, action)

          raise Actors::ActorError, I18n.t('flash.roles.permission_beyond_reach')
        end
      end
    end
  end
end
