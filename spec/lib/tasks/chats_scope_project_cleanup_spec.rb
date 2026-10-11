# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: `rake chats:cleanup_scope_projects`, the one-off sweep after E3
#       (Bezugs-Sammlung plan §10 S2).
# Type: Rake task spec.
# Why:  The service has its own spec; what only this level can say is the part
#       an operator sees and acts on -- DRY_RUN really writes nothing, a bad
#       DRY_RUN value aborts instead of being read as a real run, and the run
#       announces its own non-repeatability. The last one matters more here than
#       for any other task in this file: running it twice is harmless today and
#       destructive the moment somebody chooses a project on a thread that carries
#       references, which is a state this very cut made legitimate.
#
# ⚠️ And the property that keeps it out of the deploy hook is pinned as DATA, not
# as prose: the hook file must not name this task. A line added there would wipe a
# user's chosen project at every deploy, for ever, and nothing else in the tree
# would say so.
RSpec.describe 'chats:cleanup_scope_projects' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('chats:cleanup_scope_projects')
  end

  before { Rake::Task['chats:cleanup_scope_projects'].reenable }
  after { ENV.delete('DRY_RUN') }

  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation, name: 'Nordlicht Software') }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }

  def inherited_thread
    chat = create(:chat, :org_thread, organisation: organisation, user: user, scope_project: project)
    chat.update_column(:scope_references,
                       [Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: ticket.id)])
    chat
  end

  def run!
    Rake::Task['chats:cleanup_scope_projects'].invoke
  end

  def reload(chat)
    ActsAsTenant.without_tenant { Chat.find(chat.id) }
  end

  it 'clears the inherited project and says how many it touched' do
    chat = inherited_thread

    expect { run! }.to output(/1 Verlaeufe.*zurueckgesetzt/).to_stdout

    expect(reload(chat).scope_project_id).to be_nil
  end

  it 'writes nothing under DRY_RUN, and says so' do
    chat = inherited_thread
    ENV['DRY_RUN'] = '1'

    expect { run! }.to output(/DRY_RUN.*1 Verlaeufe wuerden.*nichts geschrieben/m).to_stdout

    expect(reload(chat).scope_project_id).to eq(project.id)
  end

  # ⚠️ Reading DRY_RUN=ja as a REAL run is the dangerous direction, and every
  # procedure in this file starts with the preview. Shared with the other chats
  # tasks (chats_dry_run!), pinned here because this is the one whose second run
  # can destroy a choice.
  it 'aborts on a DRY_RUN value it does not understand' do
    inherited_thread
    ENV['DRY_RUN'] = 'ja'

    expect { run! }.to raise_error(SystemExit).and output(/nicht verstanden/).to_stderr
  end

  # A silent zero run reads as success. Here it usually means "already ran", which
  # is the normal state of a one-off sweep, so it gets a sentence of its own.
  it 'says why it did nothing rather than finishing silently' do
    expect { run! }.to output(/Nichts geraeumt/).to_stdout
  end

  # ⚠️ THE property, pinned as data. See the file header: this task in the deploy
  # hook would wipe a deliberately chosen project at every deploy. Its neighbour
  # chats:backfill_scope_references belongs there and IS there -- the difference
  # is whether the WHERE can become satisfiable again, and only this cell states
  # it where a future hand would look.
  it 'is not wired into the data backfills' do
    expect(Lalabase::DataBackfills::TASKS).to include('chats:backfill_scope_references')
    expect(Lalabase::DataBackfills::TASKS).not_to include('chats:cleanup_scope_projects')
  end

  # ⚠️ The reason this task reports ROWS and not just a number. Two counts cannot
  # be compared -- "1" in the preview and "1" in the run can be two different
  # threads -- and once update_all has run, the old value exists nowhere. This
  # block IS the rollback: thread, and the project that was in the column.
  it 'names the rows it cleared, so the run can be undone from its own output' do
    chat = inherited_thread

    expect { run! }.to output(/#{chat.id}.*#{project.id}/).to_stdout
  end

  it 'previews the same rows the real run clears' do
    chat = inherited_thread
    ENV['DRY_RUN'] = '1'

    expect { run! }.to output(/#{chat.id}.*#{project.id}/).to_stdout
  end

  # A run that reports only what it cleared hides what it walked past. The two
  # skipped verdicts are the ones an operator has to see: "chosen" says the
  # sharpened criterion did its work, "undecidable" says a thread needs a human.
  it 'says what it left alone, and under which verdict' do
    chosen_elsewhere = create(:project, organisation: organisation, name: 'Bewusst gewaehlt')
    chat = create(:chat, :org_thread, organisation: organisation, user: user, scope_project: chosen_elsewhere)
    chat.update_column(:scope_references,
                       [Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: ticket.id)])

    expect { run! }.to output(/1 mit selbst gewaehltem Projekt/).to_stdout

    expect(reload(chat).scope_project_id).to eq(chosen_elsewhere.id)
  end

  # ⚠️ The service refuses when the registry grows past what it can map; the task
  # has to turn that into an operator sentence rather than a backtrace, and it must
  # NOT be swallowed into a green-looking zero run.
  it 'aborts instead of sweeping when the registry knows an unmapped type' do
    inherited_thread
    allow(Assistant::ReferenceRegistry).to receive(:types).and_return(%w[Ticket UnknownType])

    expect { run! }.to raise_error(SystemExit).and output(/UnknownType/).to_stderr
  end
end
