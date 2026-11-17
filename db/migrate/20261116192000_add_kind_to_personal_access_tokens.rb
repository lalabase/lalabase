# frozen_string_literal: true

# A token is either made by its owner on the token page (personal) or handed out
# by the sign-in door for a device (app_session). Every existing row is personal.
class AddKindToPersonalAccessTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :personal_access_tokens, :kind, :string, null: false, default: 'personal'
    add_check_constraint :personal_access_tokens, "kind IN ('personal', 'app_session')",
                         name: 'personal_access_tokens_kind_known'
  end
end
