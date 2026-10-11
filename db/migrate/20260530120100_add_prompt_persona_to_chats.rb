# frozen_string_literal: true

# Links a chat to its chosen persona (Plan §6.3). Nullable: NULL means "use the
# default persona" (the global `overview`), so existing chats need no backfill.
# on_delete: :nullify is enforced at the DB level (not via a Rails association
# dependent:) so deleting a persona can't leave a dangling FK regardless of the
# acts_as_tenant scope that would otherwise narrow an app-level nullify.
class AddPromptPersonaToChats < ActiveRecord::Migration[8.0]
  def change
    add_reference :chats, :prompt_persona, type: :uuid, null: true,
                                           foreign_key: { to_table: :prompt_personas, on_delete: :nullify }
  end
end
