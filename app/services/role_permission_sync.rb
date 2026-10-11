# frozen_string_literal: true

# Shared permission-sync step: for each (category, action) in the permitted permissions hash
# ({ category => { action => '1' | '0' } }), upsert the role's Permission with
# allowed = (value == '1').
#
# Extracted from the permission loop in Organisations::RolesController#update (used there via
# Actors::SaveRole). The caller owns the transaction (BaseActor) and the whitelisting
# (permission_params) — only already-permitted categories/actions reach here.
class RolePermissionSync
  def self.call(role:, permissions:)
    permissions.each do |category, actions|
      actions.each do |action, allowed|
        permission = role.permissions.find_or_initialize_by(category: category, action: action)
        permission.allowed = (allowed == '1')
        permission.save!
      end
    end
    role
  end
end
