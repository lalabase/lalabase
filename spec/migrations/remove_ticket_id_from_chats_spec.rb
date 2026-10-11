# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260826150000_remove_ticket_id_from_chats')

# S4-T1: this migration is the one riegel between a forgotten sweep and a silent
# DROP of somebody's conversation (assistant plan §13-18). Its happy path runs on
# every schema load; the refusal never does unless a spec plants a ticket thread
# and asks. #down restores the pre-S4 shape inside the example's transaction
# (Postgres DDL is transactional), so every example starts from the old world.
RSpec.describe RemoveTicketIdFromChats, type: :model do
  let(:migration) { described_class.new.tap { |m| m.verbose = false } }
  let(:connection) { ActiveRecord::Base.connection }
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { migration.down }

  # The column cache is process-wide and survives the rollback: without the reset
  # the next example would INSERT a ticket_id the table no longer has, and the
  # remnants guard reads Chat.column_names.
  after { Chat.reset_column_information }

  it 'refuses to run while a ticket thread exists, and drops nothing' do
    ActsAsTenant.with_tenant(organisation) do
      ticket = create(:ticket, project: project, organisation: organisation)
      chat = create(:chat, organisation: organisation)
      # The model knows neither column any more (ticket_id since S4-T1, project_id
      # since projekt_chat_abbau), so the legacy thread is planted by hand. THREE
      # columns at once, because three check constraints describe what a ticket thread
      # was: it carried a project (chats_ticket_requires_project) and it had NO owner
      # (chats_ticket_thread_has_no_owner, it was a shared lane), which in turn is
      # what chats_org_thread_requires_user allows only because project_id is set.
      connection.execute(
        "UPDATE chats SET ticket_id = '#{ticket.id}', project_id = '#{project.id}', " \
        "user_id = NULL WHERE id = '#{chat.id}'"
      )
    end

    expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /1 ticket thread.* still exist/)
    expect(connection.column_exists?(:chats, :ticket_id)).to be(true)
    expect(connection.foreign_key_exists?(:chats, :tickets, column: :ticket_id)).to be(true)
    expect(connection.check_constraints(:chats).map(&:name))
      .to include('chats_ticket_requires_project', 'chats_ticket_thread_has_no_owner')
  end

  it 'drops column, index, foreign key and both check constraints once no ticket thread is left' do
    migration.up

    expect(connection.column_exists?(:chats, :ticket_id)).to be(false)
    expect(connection.index_name_exists?(:chats, 'index_chats_on_ticket_id')).to be(false)
    # By COLUMN since S4-T2: chats points at tickets a second time now
    # (scope_ticket_id, the reference of §7.3), and the bare table-to-table
    # question answers "yes" for that one -- which would have read as the old
    # ownership surviving the migration.
    expect(connection.foreign_key_exists?(:chats, :tickets, column: :ticket_id)).to be(false)
    expect(connection.check_constraints(:chats).map(&:name))
      .not_to include('chats_ticket_requires_project', 'chats_ticket_thread_has_no_owner')
  end
end
