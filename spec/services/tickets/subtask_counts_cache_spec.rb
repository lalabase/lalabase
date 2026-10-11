# frozen_string_literal: true

require 'rails_helper'

# What: Tickets::SubtaskCountsCache, the numbers behind the "Subs" column.
# Type: service spec with real records and real status definitions.
# Why: "done" is the project's configured word, not a string, a page is counted
#   in a fixed number of queries whatever its length, and a row the preload
#   never saw is counted rather than shown as "none".
RSpec.describe Tickets::SubtaskCountsCache, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:parent) { create(:ticket, project: project) }
  let(:cache) { described_class.new }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:ticket_attribute_definition,
           project: project, name: 'status', field_type: 'select', system: true,
           options: { 'allowed_values' => [
             { 'value' => 'Offen', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] },
             { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] },
             { 'value' => 'Verworfen', 'labels' => { 'de' => 'Verworfen' }, 'system_functions' => ['is_closed'] }
           ] })
  end

  after { ActsAsTenant.current_tenant = nil }

  def child(status, of: parent)
    create(:ticket, project: project, parent: of, custom_attributes: status ? { 'status' => status } : {})
  end

  it 'counts every child and, as done, those whose status is completed or closed' do
    child('Erledigt')
    child('Verworfen')
    child('Offen')
    child(nil)

    expect(cache.preload([parent]).fetch(parent)).to eq(done: 2, total: 4)
  end

  # An unsaved ticket has no children. Asked by its id, nil, it would count every top-level
  # ticket of the tenant (where parent_id IS NULL) - a number that looks like an answer.
  it 'answers the empty entry for a ticket without an id, without asking' do
    child('Offen', of: nil)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == 'SCHEMA' }

    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      expect(cache.fetch(Ticket.new(project: project))).to eq(done: 0, total: 0)
    end
    expect(count).to eq(0)
  end

  it 'answers zero for a ticket without children, preloaded or not' do
    expect(cache.preload([parent]).fetch(parent)).to eq(done: 0, total: 0)
    expect(described_class.new.fetch(create(:ticket, project: project))).to eq(done: 0, total: 0)
  end

  # Boundary on the other side: children, none done. "0/2" is a real answer
  # and must not collapse into the empty entry.
  it 'keeps the total when no child is done' do
    child('Offen')
    child('Offen')

    expect(cache.preload([parent]).fetch(parent)).to eq(done: 0, total: 2)
  end

  it 'keeps each parent to its own children' do
    other = create(:ticket, project: project)
    child('Erledigt')
    child('Offen', of: other)
    child('Offen', of: other)

    cache.preload([parent, other])
    expect(cache.fetch(parent)).to eq(done: 1, total: 1)
    expect(cache.fetch(other)).to eq(done: 0, total: 2)
  end

  it 'counts a row the preload never saw instead of reporting it empty' do
    child('Erledigt')
    cache.preload([create(:ticket, project: project)])

    expect(cache.fetch(parent)).to eq(done: 1, total: 1)
  end

  # A childless ticket on the page as well: the preload must answer it too,
  # or its fetch falls through to a query of its own and the count below grows.
  it 'counts a page in the same number of queries, whatever its length' do
    parents = Prosopite.pause do
      Array.new(4) { create(:ticket, project: project) }.each { |p| child('Erledigt', of: p) } +
        [create(:ticket, project: project)]
    end

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      described_class.new.preload(parents).then { |c| parents.each { |p| c.fetch(p) } }
    end

    # Status values, all children, the done ones.
    expect(queries).to eq(3)
  end

  # "Done" is each project's own word. The list shows one project, but the
  # cache takes any tickets, and must never lend one project's word to another.
  # One pass PER PROJECT is the design (see the class comment), so Prosopite is
  # paused: its N+1 here is two projects, not two rows.
  it 'reads done from the project of each ticket within one preload' do
    other_project = create(:project, organisation: organisation)
    create(:ticket_attribute_definition,
           project: other_project, name: 'status', field_type: 'select', system: true,
           options: { 'allowed_values' => [
             { 'value' => 'Fertig', 'labels' => { 'de' => 'Fertig' }, 'system_functions' => ['is_completed'] },
             { 'value' => 'Offen', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] }
           ] })
    other_parent = create(:ticket, project: other_project)
    create(:ticket, project: other_project, parent: other_parent, custom_attributes: { 'status' => 'Fertig' })
    create(:ticket, project: other_project, parent: other_parent, custom_attributes: { 'status' => 'Fertig' })
    child('Erledigt')
    child('Offen')

    # Asymmetric on purpose: with this project's words the other parent would
    # read 0/2, with the other project's words this one would read 0/2.
    Prosopite.pause { cache.preload([parent, other_parent]) }
    expect(cache.fetch(parent)).to eq(done: 1, total: 2)
    expect(cache.fetch(other_parent)).to eq(done: 2, total: 2)
  end

  # Defense in depth: a child written past the validations into another
  # organisation must not show up in this organisation's count.
  it 'does not count a child of another organisation' do
    child('Offen')
    foreign_org = create(:organisation)
    ActsAsTenant.with_tenant(foreign_org) do
      foreign = create(:ticket, project: create(:project, organisation: foreign_org))
      foreign.update_column(:parent_id, parent.id)
    end

    expect(cache.preload([parent]).fetch(parent)).to eq(done: 0, total: 1)
  end
end
