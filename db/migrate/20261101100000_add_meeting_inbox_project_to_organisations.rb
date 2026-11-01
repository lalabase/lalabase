# frozen_string_literal: true

# The project a meeting lands in when a client sends one without a project.
# Nullable: an organisation chooses one or has none. on_delete nullify, so a
# deleted project clears the choice in every delete path, the one that takes a
# whole organisation along included. An archived project keeps the column and
# counts as not set (Organisation#meeting_inbox), so restoring it brings the
# inbox back.
class AddMeetingInboxProjectToOrganisations < ActiveRecord::Migration[8.1]
  def change
    add_reference :organisations, :meeting_inbox_project, type: :uuid,
                                                          foreign_key: { to_table: :projects, on_delete: :nullify }
  end
end
