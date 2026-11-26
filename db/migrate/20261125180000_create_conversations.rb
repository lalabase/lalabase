# frozen_string_literal: true

# Conversations: messages between members of one organisation. Three tables, all
# empty until a later change writes to them, with every column those changes
# will fill, so they need no migration of their own.
#
# conversations: one row per conversation. The project is a label and may go
# (on_delete: :nullify); it gives no right to read. frozen_at and
# read_by_departed_until are filled when the last participant has left.
#
# conversation_participants: the list that decides who reads. A row names an
# account (user_id is not null), and a participation ends by deleting the row,
# never by a flag: a forgotten "and not ended" would be a leak, a missing row
# cannot be. The read and mail columns hold one person's own state.
#
# conversation_posts: a message or a system entry. The text of a message is an
# Action Text record (has_rich_text), not a column here; plain_text_version and
# plain_text_word_count mirror it. A system entry holds a key and ids, never a
# name or a sentence, so nothing personal stays in it when an account is
# erased. origin says through which door a post came.
#
# The organisation takes its rows with it (on_delete: :cascade), and so does a
# conversation. ⚠️ That cascade removes rows, never the Action Text record of a
# post: a conversation is deleted through the model (dependent: :destroy).
# A required reference to users has no delete rule: an account is never
# deleted as a row, it is anonymised.
class CreateConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :conversations, id: :uuid do |t|
      # No index of its own: the index on (organisation_id, last_post_at) starts with it.
      t.references :organisation, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :creator, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string :title, limit: 255
      t.datetime :last_post_at, null: false
      t.datetime :read_by_departed_until
      t.datetime :frozen_at
      t.timestamps
      # The order of the list inside one organisation.
      t.index %i[organisation_id last_post_at], order: { last_post_at: :desc }
      t.index :frozen_at, where: 'frozen_at IS NOT NULL'
    end

    create_table :conversation_participants, id: :uuid do |t|
      # No index: every read comes with a conversation or a user, and an
      # organisation is deleted rarely (its conversations go through their own index).
      t.references :organisation, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      # No index of its own: the unique index on (conversation_id, user_id) starts with it.
      t.references :conversation, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      # The direction the read rule asks: the conversations of one person.
      t.references :user, type: :uuid, null: false, foreign_key: true
      # No index: only a deleted users row would look for it, and accounts are anonymised.
      t.references :added_by, type: :uuid, index: false, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :last_read_at
      t.datetime :archived_at
      t.datetime :mail_open_since
      t.datetime :mailed_until
      t.datetime :alone_notified_at
      t.timestamps
      t.index %i[conversation_id user_id], unique: true
    end

    create_table :conversation_posts, id: :uuid do |t|
      # No index: as on conversation_participants.
      t.references :organisation, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      # No index of its own: the index on (conversation_id, created_at) starts with it.
      t.references :conversation, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      # No index on the three references to users: as added_by above.
      t.references :user, type: :uuid, null: false, index: false, foreign_key: true
      t.string :kind, null: false, default: 'message'
      t.string :origin, null: false, default: 'web'
      t.string :system_event
      t.references :subject_user, type: :uuid, index: false, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :second_user, type: :uuid, index: false, foreign_key: { to_table: :users, on_delete: :nullify }
      # An index, and only for the rows that name an invitation: invitations ARE
      # deleted (revoked, or with their organisation), and each deletion makes the
      # database look for the posts that name it. Without an index that is a scan
      # of every post of the instance.
      t.references :invitation, type: :uuid, foreign_key: { on_delete: :nullify },
                                index: { where: 'invitation_id IS NOT NULL' }
      t.text :plain_text_version
      t.integer :plain_text_word_count
      t.timestamps
      # The timeline of one conversation.
      t.index %i[conversation_id created_at]
      # Written as ORs, not as IN (...): Postgres keeps an IN list as an array
      # comparison, and prints that in another form once it was loaded from
      # db/schema.rb. An OR reads the same after the migration and after a load.
      t.check_constraint "kind = 'message' OR kind = 'system'", name: 'conversation_posts_kind_known'
      t.check_constraint "origin = 'web' OR origin = 'token' OR origin = 'assistant'",
                         name: 'conversation_posts_origin_known'
      t.check_constraint "(kind = 'message' AND system_event IS NULL) OR " \
                         "(kind = 'system' AND system_event IS NOT NULL)",
                         name: 'conversation_posts_system_event_by_kind'
    end
  end
end
