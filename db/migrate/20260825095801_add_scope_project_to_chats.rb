# frozen_string_literal: true

# S3a T5 (assistant plan §9.3): the scope chip. A standing narrowing of an
# org-wide thread to ONE project, chosen by its owner and visible at the input
# field.
#
# NULL means "every project the asker may read", which is the behaviour every
# existing thread has today -- hence no backfill.
#
# on_delete: :nullify rather than a cascade: a deleted project must not take a
# conversation with it. The thread simply widens back, and the chip says so
# (Tools::Scope resolves the column, the chip renders the RESOLVED value).
class AddScopeProjectToChats < ActiveRecord::Migration[8.0]
  def change
    add_reference :chats, :scope_project, type: :uuid, null: true, foreign_key: { to_table: :projects, on_delete: :nullify }, index: true
  end
end
