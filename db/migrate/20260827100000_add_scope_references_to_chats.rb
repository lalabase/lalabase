# frozen_string_literal: true

# Bezugs-Sammlung S1 (doc/assistent_bezug_sammlung_plan.md §4.1): the reference of
# an org-wide thread stops being ONE ticket column and becomes a LIST of typed
# pointers, so a second type is a registry entry rather than a migration.
#
#   [{"type": "Ticket", "id": "…uuid…"}, {"type": "Meeting", "id": "…uuid…"}]
#
# JSONB and not a table (E1): chatposts.source_citations is already a JSONB list
# of pointers at objects, and the missing foreign key hits both variants alike the
# moment the type is free. What a foreign key did for scope_ticket_id is done by
# resolving instead of trusting: Tools::Scope asks the asker's CURRENT reach per
# question, so a deleted or unreachable entry stops being a reference.
#
# `[]` and NOT NULL, so "no reference" has ONE spelling. The check constraint is
# the shape floor underneath the model's own validation (pattern:
# chats_org_thread_requires_user), and it holds for a console or an import too.
#
# No GIN index: the only query goes through the primary key. The backwards
# question ("which threads point at this object") has no use case (§14).
class AddScopeReferencesToChats < ActiveRecord::Migration[8.0]
  def change
    add_column :chats, :scope_references, :jsonb, null: false, default: []
    add_check_constraint :chats, "jsonb_typeof(scope_references) = 'array'",
                         name: 'chats_scope_references_is_array'
  end
end
