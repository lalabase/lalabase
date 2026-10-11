# frozen_string_literal: true

# S3a (doc/persoenlicher_assistent_plan.md §5.1): an org-wide personal thread is a
# chat WITHOUT a project. project_id becomes nullable; two check constraints keep
# the shape closed at the DB level (the model validates the same invariants):
#   1. a ticket thread always has a project
#   2. a project-less thread always has an owner -- without this, an org-wide
#      SHARED thread could arrive through the back door that L2 rules out.
# No data migration needed: every existing row has project_id set, so both
# constraints hold for the whole table already.
class AllowOrgWideChats < ActiveRecord::Migration[8.0]
  def change
    change_column_null :chats, :project_id, true

    add_check_constraint :chats,
                         'ticket_id IS NULL OR project_id IS NOT NULL',
                         name: 'chats_ticket_requires_project'
    add_check_constraint :chats,
                         'project_id IS NOT NULL OR user_id IS NOT NULL',
                         name: 'chats_org_thread_requires_user'
  end
end
