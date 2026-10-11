# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake chats:backfill_scope_references`, the copy from the old single
#       reference column into the new collection (Bezugs-Sammlung §4.3, T-11).
# Type: Rake task spec.
# Why:  It is listed in Lalabase::DataBackfills, so it runs on EVERY deploy, on the
#       primary DB host, between deploy:migrate and the restart. Three things
#       therefore have to hold and none of them is visible from the SQL alone:
#       it is idempotent, DRY_RUN writes nothing, and it MOVES rather than
#       copies (the source column is emptied in the same statement) -- that last
#       one is what keeps a later deploy from putting back a reference the owner
#       removed, and nothing else in the tree says so.
#
# ⚠️ Everything here goes through raw SQL, on both sides. The source column is
# in Chat.ignored_columns, so the Ruby side cannot see it -- which is exactly
# why the task itself is raw SQL too.
RSpec.describe 'chats:backfill_scope_references' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('chats:backfill_scope_references')
  end

  before { Rake::Task['chats:backfill_scope_references'].reenable }
  after { ENV.delete('DRY_RUN') }

  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }

  def legacy_thread(ticket_id)
    chat = create(:chat, :org_thread, organisation: organisation, user: user)
    ActiveRecord::Base.connection.execute(
      "UPDATE chats SET scope_ticket_id = '#{ticket_id}' WHERE id = '#{chat.id}'"
    )
    chat
  end

  def column(chat, name)
    ActiveRecord::Base.connection.select_value("SELECT #{name} FROM chats WHERE id = '#{chat.id}'")
  end

  def references_of(chat)
    JSON.parse(column(chat, 'scope_references'))
  end

  def run(dry_run: false)
    ENV['DRY_RUN'] = dry_run ? '1' : nil
    output = StringIO.new
    original = $stdout
    $stdout = output
    Rake::Task['chats:backfill_scope_references'].invoke
    output.string
  ensure
    $stdout = original
    Rake::Task['chats:backfill_scope_references'].reenable
  end

  it 'copies the old single reference into the collection' do
    chat = legacy_thread(ticket.id)

    run

    expect(references_of(chat)).to eq([{ 'type' => 'Ticket', 'id' => ticket.id }])
  end

  # ⚠️ MOVED, not copied (review of this slice): the source is emptied in the
  # same statement, so the WHERE never matches this row again -- that is what
  # keeps a later deploy from resurrecting a reference the owner has since
  # removed (next cell). A rollback of this slice then HIDES the moved reference
  # under the old code, which reads NULL, rather than losing it: the list keeps
  # it and a redeploy shows it again.
  it 'empties the source column in the same statement that fills the list' do
    chat = legacy_thread(ticket.id)

    run

    expect(column(chat, 'scope_ticket_id')).to be_nil
  end

  # ⚠️ The cell a copy fails: run, the owner removes the reference under the new
  # code, run again (every deploy runs this task), and the reference must stay
  # gone. With a copy the WHERE (list empty, source filled) is true again and the
  # deploy puts the reference back -- without scope_project_id, so the reach
  # narrows while the scope chip says "all your projects". Mutation-proven: with
  # `scope_ticket_id = NULL` taken out of the statement this cell is red.
  it 'does not resurrect a reference the owner removed under the new code' do
    create(:membership, user: user, organisation: organisation,
                        role: create(:admin_role, organisation: organisation), active: true)
    chat = legacy_thread(ticket.id)
    run
    expect(references_of(chat)).to eq([{ 'type' => 'Ticket', 'id' => ticket.id }])

    Actors::RemoveChatReference.call(chat: chat.reload, type: 'Ticket', id: ticket.id, current_user: user)
    expect(references_of(chat)).to eq([])

    run

    expect(references_of(chat)).to eq([])
    expect(column(chat, 'scope_project_id')).to be_nil
  end

  # It runs on every deploy, so a second run must be a no-op -- and specifically
  # must not append a second copy of the same entry, which is what an idempotency
  # written as "WHERE scope_ticket_id IS NOT NULL" alone would do.
  it 'is idempotent' do
    chat = legacy_thread(ticket.id)

    run
    run

    expect(references_of(chat)).to eq([{ 'type' => 'Ticket', 'id' => ticket.id }])
  end

  # And it must not overwrite a collection somebody has meanwhile CHANGED. The
  # statement only moves where the list is EMPTY, so on such a row the source
  # still holds its old value and the two disagree on purpose -- the new list
  # wins, and the leftover in the source is harmless: nothing reads it, and the
  # follow-up PR drops the column.
  it 'leaves a collection alone that already says something else' do
    chat = legacy_thread(ticket.id)
    other = create(:ticket, project: project, organisation: organisation)
    ActiveRecord::Base.connection.execute(
      "UPDATE chats SET scope_references = '[{\"type\":\"Ticket\",\"id\":\"#{other.id}\"}]' WHERE id = '#{chat.id}'"
    )

    run

    expect(references_of(chat)).to eq([{ 'type' => 'Ticket', 'id' => other.id }])
  end

  it 'leaves a thread without a reference empty' do
    chat = create(:chat, :org_thread, organisation: organisation, user: user)

    run

    expect(references_of(chat)).to eq([])
  end

  # Plan §4.4 as data instead of as three comments: the entry in
  # Lalabase::DataBackfills::TASKS and the source column go together.
  # This cell goes red in exactly the follow-up PR that drops chats.scope_ticket_id
  # but leaves the line in the hook (cap would then abort between deploy:migrate
  # and the restart against a column the migration has just deleted), and in one
  # that drops the line while the column still has rows to move.
  it 'stays in the data backfills exactly as long as the source column exists' do
    expect(Lalabase::DataBackfills::TASKS.include?('chats:backfill_scope_references'))
      .to be(ActiveRecord::Base.connection.column_exists?(:chats, :scope_ticket_id))
  end

  describe 'DRY_RUN' do
    it 'writes nothing and counts what it would do' do
      chat = legacy_thread(ticket.id)

      output = run(dry_run: true)

      expect(references_of(chat)).to eq([])
      expect(output).to include('(DRY_RUN): 1 Verlaeufe')
    end

    # An unreadable switch aborts loudly rather than being read as a real run:
    # both procedures in this file start with the preview, and guessing is
    # dangerous in exactly one direction.
    it 'aborts on a value it does not understand' do
      ENV['DRY_RUN'] = 'vielleicht'

      expect { Rake::Task['chats:backfill_scope_references'].invoke }.to raise_error(SystemExit)
    end
  end
end
