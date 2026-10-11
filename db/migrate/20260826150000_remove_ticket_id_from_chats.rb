# frozen_string_literal: true

# S4-T1 (assistant plan §10 S4, §13-3, §13-18): the ticket chat is dissolved, so
# the column that made a chat a ticket thread goes, together with the two check
# constraints, the partial unique index and the foreign key that shaped it.
#
# NO data is deleted here. The remaining ticket threads are removed by the
# operator-run sweep BEFORE this deploys (plan §13-18): on the release that is
# current until then, `rake chats:purge_legacy_threads INCLUDE_TICKET_THREADS=1`;
# this release's sweep takes them along without a switch as long as the column
# exists. The migration only refuses to run while any are left, loudly, so a
# forgotten sweep cannot turn into a silent DROP of somebody's conversation.
class RemoveTicketIdFromChats < ActiveRecord::Migration[8.0]
  def up
    # The old app is still live while this runs: take the DDL's own lock BEFORE the
    # count, so a thread created between count and DROP cannot slip through. The lock
    # ends with the migration's transaction, chats is a small table, and a queued
    # ALTER fails after 5s instead of stalling every query on chats and tickets.
    execute("SET LOCAL lock_timeout = '5s'")
    execute('LOCK TABLE chats IN ACCESS EXCLUSIVE MODE')
    remaining = select_value('SELECT COUNT(*) FROM chats WHERE ticket_id IS NOT NULL').to_i
    if remaining.positive?
      raise ActiveRecord::MigrationError,
            "#{remaining} ticket thread(s) still exist. Delete them first (plan §13-18): on the " \
            'release that is current before this deploy, rake chats:purge_legacy_threads ' \
            'INCLUDE_TICKET_THREADS=1; on this release the sweep takes them along without a switch.'
    end

    remove_check_constraint :chats, name: 'chats_ticket_requires_project'
    remove_check_constraint :chats, name: 'chats_ticket_thread_has_no_owner'
    remove_index :chats, name: 'index_chats_on_ticket_id'
    remove_foreign_key :chats, :tickets
    remove_column :chats, :ticket_id
  end

  # Restores the shape, not the data: the threads themselves were removed by the
  # sweep, and nothing here can bring them back. Same lock budget as #up: ADD
  # COLUMN, ADD FOREIGN KEY (locks tickets too) and the non-concurrent index would
  # otherwise queue behind a long transaction without bound, blocking every new
  # query on chats while they wait.
  def down
    execute("SET LOCAL lock_timeout = '5s'")
    add_column :chats, :ticket_id, :uuid
    add_foreign_key :chats, :tickets
    add_index :chats, :ticket_id, unique: true, where: 'ticket_id IS NOT NULL'
    add_check_constraint :chats, 'ticket_id IS NULL OR project_id IS NOT NULL',
                         name: 'chats_ticket_requires_project'
    add_check_constraint :chats, 'ticket_id IS NULL OR user_id IS NULL',
                         name: 'chats_ticket_thread_has_no_owner'
  end
end
