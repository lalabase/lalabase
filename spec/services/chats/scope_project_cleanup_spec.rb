# frozen_string_literal: true

require 'rails_helper'

# What: Chats::ScopeProjectCleanup, the one-off sweep that E3 leaves behind
#       (Bezugs-Sammlung plan §10 S2).
# Type: Service spec.
# Why:  Until S2 a reference WROTE its object's project into scope_project_id.
#       After the decoupling nobody writes that column but the user, so every
#       thread that ever carried a reference is left claiming a narrowing its
#       owner never chose -- and the column cannot say who put it there. The
#       sweep clears exactly those, once.
#
# ⚠️ This is the run that must NOT go into Lalabase::DataBackfills, and the reason
# is the shape of its WHERE: it never runs empty. After E3 a thread may perfectly
# well carry references AND a deliberately chosen project, so at every following
# deploy the hook would wipe that choice again. (The §4.3 backfill may live in the
# hook because its WHERE stops being satisfiable after the first run.) The same
# question, answered both ways one page apart, is what Rev. 7 of the plan is about.
RSpec.describe Chats::ScopeProjectCleanup do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation, name: 'Nordlicht Software') }
  let(:ticket) { create(:ticket, project: project, organisation: organisation) }

  def thread_with(references:, scope_project: nil)
    ActsAsTenant.with_tenant(organisation) do
      chat = create(:chat, :org_thread, organisation: organisation, user: user, scope_project: scope_project)
      chat.update_column(:scope_references, references)
      chat
    end
  end

  def reference_to(record)
    Assistant::ReferenceRegistry.stored_entry(type: record.class.name, id: record.id)
  end

  def reload(chat)
    ActsAsTenant.without_tenant { Chat.find(chat.id) }
  end

  # THE case: a thread from before the decoupling. Both halves in one example --
  # "clears it" is true of a sweep that clears every thread in the estate, so the
  # untouched neighbour has to stand right beside it.
  it 'clears the project a reference had written, and leaves a chosen one alone' do
    inherited = thread_with(references: [reference_to(ticket)], scope_project: project)
    chosen = thread_with(references: [], scope_project: project)

    result = described_class.call

    expect(result.cleared).to eq(1)
    expect(reload(inherited).scope_project_id).to be_nil
    expect(reload(chosen).scope_project_id).to eq(project.id)
  end

  # The collection is not this sweep's business. It clears ONE column, and a
  # version that emptied the list as well would leave every affected user without
  # the reference they set.
  it 'does not touch the reference list itself' do
    chat = thread_with(references: [reference_to(ticket)], scope_project: project)

    described_class.call

    expect(reload(chat).scope_references).to eq([reference_to(ticket)])
  end

  # A thread with references but no project is not a candidate: there is nothing
  # to clear, and counting it would tell the operator a number that does not match
  # what changed.
  it 'counts only the threads it actually changes' do
    thread_with(references: [reference_to(ticket)], scope_project: nil)

    expect(described_class.call.cleared).to eq(0)
  end

  # The preview the procedure starts with. Reading "3 threads" and then finding
  # nothing written is the whole point of a dry run, and the number has to be the
  # same one the real run reports.
  it 'writes nothing in a dry run and reports what the real run would do' do
    chat = thread_with(references: [reference_to(ticket)], scope_project: project)

    expect(described_class.call(dry_run: true).cleared).to eq(1)
    expect(reload(chat).scope_project_id).to eq(project.id)

    expect(described_class.call.cleared).to eq(1)
    expect(reload(chat).scope_project_id).to be_nil
  end

  # ⚠️ A maintenance sweep is not tenant-scoped, and this is the cell that says so.
  # Chats ARE (acts_as_tenant), so without `without_tenant` the run reports a clean
  # finish having seen exactly one organisation -- and the operator reads that as
  # done. Same decision and same reason as Chats::OwnerBackfill.
  it 'reaches across organisations, not just the current tenant' do
    here = thread_with(references: [reference_to(ticket)], scope_project: project)

    other_org = ActsAsTenant.without_tenant { create(:organisation) }
    there = ActsAsTenant.with_tenant(other_org) do
      other_project = create(:project, organisation: other_org, name: 'Fremdprojekt')
      other_ticket = create(:ticket, project: other_project, organisation: other_org)
      chat = create(:chat, :org_thread, organisation: other_org, user: create(:user),
                                        scope_project: other_project)
      chat.update_column(:scope_references, [reference_to(other_ticket)])
      chat
    end

    # Run with a tenant SET, which is the situation a rake task in this app is in
    # by default -- the sweep has to break out of it by itself.
    result = ActsAsTenant.with_tenant(organisation) { described_class.call }

    expect(result.cleared).to eq(2)
    expect(reload(here).scope_project_id).to be_nil
    expect(reload(there).scope_project_id).to be_nil
  end

  # Was: "leaves project threads alone". scope_project_id is a property of the org-wide
  # thread (S3a T5), and the sweep deliberately did not reach into a project chat, which
  # was already confined by its own column. projekt_chat_abbau removed that kind of
  # thread; what is left of the rule is that the sweep only touches a thread that BOTH
  # carries references and has a scope_project. Pinned here on the second condition.
  it 'leaves a thread with a scope_project but no references alone' do
    chat = ActsAsTenant.with_tenant(organisation) do
      create(:chat, organisation: organisation, scope_project: project)
    end

    expect(described_class.call.cleared).to eq(0)
    expect(reload(chat).scope_project_id).to eq(project.id)
  end

  # ⚠️ THE cell of this fix: the sweep's premise was false, and not only in the
  # window between deploy and run that the plan named. "The thread carries
  # references" was read as "the project was inherited". It never was. On the
  # DEPLOYED code the chip is a free select (scope_chip_component.html.erb, and
  # assistant_chats_controller permits chat[scope_project_id]), never disabled
  # while a reference stands -- so a user could set a reference and THEN choose a
  # different project, months before this deploy, and the sweep would have deleted
  # that choice silently and for good.
  #
  # The signal that DOES carry: only Actors::AddChatReference ever wrote the column
  # on the user's behalf, and it wrote exactly `added.project_id`. A chip naming a
  # project that none of the thread's references lives in therefore cannot be
  # inherited, whatever else it is.
  it 'leaves a chip that names a project none of the references lives in' do
    elsewhere = create(:project, organisation: organisation, name: 'Bewusst gewaehlt')
    chat = thread_with(references: [reference_to(ticket)], scope_project: elsewhere)

    result = described_class.call

    expect(result.cleared).to eq(0)
    expect(result.kept_chosen).to eq(1)
    expect(reload(chat).scope_project_id).to eq(elsewhere.id)
  end

  # A reference whose object is gone cannot say which project it lived in, so for
  # this thread the sweep has no evidence either way and leaves it.
  #
  # ⚠️ Counting it as "chosen" or as "inherited" would both be a guess, and one of
  # them deletes. The only honest answer for a missing witness is a separate
  # number the operator can look at.
  it 'leaves a thread whose reference no longer resolves, and counts it apart' do
    vanished = Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: SecureRandom.uuid)
    chat = thread_with(references: [vanished], scope_project: project)

    result = described_class.call

    expect(result.cleared).to eq(0)
    expect(result.undecidable).to eq(1)
    expect(reload(chat).scope_project_id).to eq(project.id)
  end

  # ⚠️ Same answer for a list that survives the SQL filter but yields no pair. The
  # filter counts entries RAW (jsonb_array_length), the registry drops malformed and
  # unregistered ones -- so "has references" and "has references we understand" are
  # two questions, and the gap between them is a thread about which we know nothing.
  it 'treats a list of unreadable entries as undecidable, not as chosen' do
    chat = thread_with(references: [{ 'type' => 'Rumpelstilzchen', 'id' => SecureRandom.uuid }],
                       scope_project: project)

    result = described_class.call

    expect(result.cleared).to eq(0)
    expect(result.undecidable).to eq(1)
    expect(reload(chat).scope_project_id).to eq(project.id)
  end

  # ⚠️ What makes the run checkable and reversible, and it is the other half of this
  # fix. A bare count cannot be compared with the preview's count -- the same number
  # can be a different set of threads -- and once update_all has run, nothing
  # anywhere says which chip held which project. These rows ARE the rollback.
  it 'names the rows it clears, so preview and run can be compared' do
    chat = thread_with(references: [reference_to(ticket)], scope_project: project)

    preview = described_class.call(dry_run: true)
    real = described_class.call

    expect(preview.rows.map(&:to_a)).to eq(real.rows.map(&:to_a))
    expect(real.rows.map(&:chat_id)).to eq([chat.id])
    expect(real.rows.map(&:project_id)).to eq([project.id])
    expect(real.rows.map(&:organisation_id)).to eq([organisation.id])
  end

  # ⚠️ Two lists are comparable only if they arrive in the same order. Without an
  # explicit ORDER BY, Postgres may hand the same rows back differently between the
  # preview and the run, and the operator's diff would show a difference that is
  # not there -- which is worse than no list, because it is a list that lies.
  it 'lists the rows in a stable order' do
    3.times { thread_with(references: [reference_to(ticket)], scope_project: project) }

    preview = described_class.call(dry_run: true)
    ids = preview.rows.map(&:chat_id)

    expect(ids).to eq(ids.sort)
    expect(described_class.call.rows.map(&:chat_id)).to eq(ids)
  end

  # ⚠️ Fail closed when the registry grows (as it did when 'Meeting' joined ENTRIES in S3); a sweep
  # that quietly skipped the type it cannot map would decide on the evidence of the
  # references it DOES understand -- for a thread whose meeting reference may well
  # be the one that wrote the chip.
  #
  # Keyed on the REGISTRY, not on the data that happens to be there: a
  # data-dependent abort is invisible in every test run and turns up on an
  # operator's terminal at the worst possible moment.
  # The positive half: the map keeps up with the registry as it stands. The
  # refusal below proves the guard bites; this proves it does not bite TODAY --
  # the knowledge objects joined the registry (doc/assistent_wissen_kontext_plan.md)
  # and both carry a project_id, so they are mapped here.
  it 'maps every type the registry knows today' do
    expect(Assistant::ReferenceRegistry.types - described_class::PROJECT_ID_BY_TYPE.keys).to be_empty
  end

  it 'refuses to run when the registry knows a type it cannot map to a project' do
    chat = thread_with(references: [reference_to(ticket)], scope_project: project)
    allow(Assistant::ReferenceRegistry).to receive(:types).and_return(%w[Ticket UnknownType])

    expect { described_class.call }.to raise_error(described_class::UnmappedType, /UnknownType/)
    expect(reload(chat).scope_project_id).to eq(project.id)
  end
end
