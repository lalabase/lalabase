# frozen_string_literal: true

require 'rails_helper'

# What: the shared normalisation both reference actors run under the row lock
#       (Bezugs-Sammlung §7.2).
# Type: Service spec.
# Why:  The plan puts ONE term on three different failures -- gone, out of reach,
#       type deregistered -- and that is only defensible because a thread has
#       exactly one owner, so "resolvable" is unambiguous. This file is where the
#       three are shown to answer alike, and where the two properties that are
#       easy to lose are pinned: the surviving order, and the fact that nothing
#       here is a SECOND rights check (it asks Tools::Scope, like the read path).
RSpec.describe Chats::ReferenceNormalizer do
  let(:organisation) { create(:organisation) }

  # before/after and NOT around: a global config.before(:each) resets the tenant
  # (spec/support/database_cleaner.rb), and RSpec runs `around` OUTSIDE it -- an
  # around block setting the tenant is wiped before the first line of the example.
  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:user) do
    account = create(:user)
    create(:membership, user: account, organisation: organisation,
                        role: create(:admin_role, organisation: organisation), active: true)
    account
  end

  let(:project) { create(:project, organisation: organisation) }

  def ticket
    create(:ticket, project: project, organisation: organisation)
  end

  def entry(record_or_id)
    id = record_or_id.respond_to?(:id) ? record_or_id.id : record_or_id
    Assistant::ReferenceRegistry.stored_entry(type: 'Ticket', id: id)
  end

  def thread_with(entries)
    chat = create(:chat, :org_thread, organisation: organisation, user: user)
    chat.update_column(:scope_references, entries)
    chat.reload
  end

  it 'keeps an entry that still resolves' do
    kept = ticket

    expect(described_class.call(chat: thread_with([entry(kept)]), actor: user)).to eq([entry(kept)])
  end

  # The three drop reasons, one word. Each stands next to the survivor in the same
  # list, so "returns nothing" cannot pass any of them.
  it 'drops an entry whose object is gone' do
    alive = ticket
    dead = ticket
    chat = thread_with([entry(dead), entry(alive)])
    dead.destroy!

    expect(described_class.call(chat: chat, actor: user)).to eq([entry(alive)])
  end

  it 'drops an entry that is out of reach' do
    alive = ticket
    elsewhere_project = create(:project, organisation: organisation)
    far = create(:ticket, project: elsewhere_project, organisation: organisation)
    chat = thread_with([entry(far), entry(alive)])
    elsewhere_project.update!(archived_at: Time.current)

    expect(described_class.call(chat: chat, actor: user)).to eq([entry(alive)])
  end

  it 'drops an entry of a type the registry no longer knows' do
    alive = ticket
    chat = thread_with([{ 'type' => 'Invoice', 'id' => SecureRandom.uuid }, entry(alive)])

    expect(described_class.call(chat: chat, actor: user)).to eq([entry(alive)])
  end

  it 'drops a stored value that is not a pair at all' do
    alive = ticket
    chat = thread_with(['Ticket', { 'type' => 'Ticket' }, entry(alive)])

    expect(described_class.call(chat: chat, actor: user)).to eq([entry(alive)])
  end

  # ⚠️ The order is the collection's identity (§4.1: insertion order), and
  # grouping by type is what loses it. Three entries, and the middle one dropped,
  # so a normaliser that rebuilt the list out of the resolved records in QUERY
  # order would come back sorted by id instead.
  it 'keeps the surviving entries in their stored order' do
    three = Array.new(3) { ticket }
    stored = [three[2], three[0], three[1]]
    chat = thread_with(stored.map { |record| entry(record) })
    three[0].destroy!

    expect(described_class.call(chat: chat, actor: user)).to eq([entry(three[2]), entry(three[1])])
  end

  # The answer is in the STORED form, ready to be written back. A symbol-keyed
  # hash would round-trip through jsonb into string keys and make every
  # comparison against the column a false negative.
  it 'answers in the form the column stores' do
    kept = ticket

    expect(described_class.call(chat: thread_with([entry(kept)]), actor: user).first.keys).to eq(%w[type id])
  end

  # A project thread has no reference collection at all (Tools::Scope.for answers
  # nil for anything that is not an org thread), and the honest answer to "what
  # survives" there is nothing -- not a crash.
  it 'answers empty for a thread that has no collection' do
    chat = create(:chat, organisation: organisation)

    expect(described_class.call(chat: chat, actor: user)).to eq([])
  end

  # A write that already holds a Tools::Scope hands it in, so the asker's reach
  # is not resolved a second time under the row lock (area_reach is memoised per
  # instance). Pinned on the constructor: handed a scope, the normaliser must not
  # build one of its own.
  it 'uses the scope it is handed instead of building a second one' do
    kept = ticket
    chat = thread_with([entry(kept)])
    scope = Lalabase::Tools::Scope.for(chat: chat, actor: user)
    allow(Lalabase::Tools::Scope).to receive(:for).and_call_original

    expect(described_class.call(chat: chat, actor: user, scope: scope)).to eq([entry(kept)])
    expect(Lalabase::Tools::Scope).not_to have_received(:for)
  end
end
