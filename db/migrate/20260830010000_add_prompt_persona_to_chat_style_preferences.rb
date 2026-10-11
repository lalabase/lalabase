# frozen_string_literal: true

# The per-user persona choice (assistant settings, doc/assistent_persona_einstellungen_plan.md).
#
# Joins the row that already answers "how should the assistant talk to me"
# (technicality, length) rather than opening a table of its own: the job renders
# all three next to each other in ONE prompt block.
#
# NULL means "the organisation's default persona", which is exactly what every
# existing row means today, so no backfill and no data migration.
class AddPromptPersonaToChatStylePreferences < ActiveRecord::Migration[8.0]
  def change
    add_reference :chat_style_preferences, :prompt_persona, type: :uuid, null: true,
                                                            foreign_key: { on_delete: :nullify }
  end
end
