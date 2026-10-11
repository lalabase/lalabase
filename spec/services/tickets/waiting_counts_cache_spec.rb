# frozen_string_literal: true

require 'rails_helper'

# What: Tickets::WaitingCountsCache, the numbers behind the "Wartet" column, the board's and
#   the phone row's hourglass (doc/ticket_relations_plan.md, revision 4, §8.3, §8.4).
# Type: service spec with real records and real status definitions.
# Why: the numbers are Tickets::Waiting's (tickets, not edges; done per project), a page is
#   counted in a fixed number of queries whatever its length, and a row the preload never saw
#   counts itself instead of showing "not waiting".
RSpec.describe Tickets::WaitingCountsCache do
  let(:organisation) { create(:organisation) }
  let(:project) { new_project }
  let(:cache) { described_class.new }

  before do
    ActsAsTenant.current_tenant = organisation
    status_field(project)
  end

  after { ActsAsTenant.current_tenant = nil }

  def new_project
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  def status_field(project, options = { 'Offen' => 'is_new', 'Erledigt' => 'is_completed' })
    allowed_values = options.map do |value, function|
      { 'value' => value, 'labels' => { 'de' => value }, 'system_functions' => [function] }
    end
    create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select', system: true,
                                         options: { 'allowed_values' => allowed_values })
  end

  def ticket(status = 'Offen', in_project: project)
    Prosopite.pause { create(:ticket, project: in_project, custom_attributes: { 'status' => status }) }
  end

  def link(source, target, type = :blocks)
    Prosopite.pause { TicketRelation.create!(source_ticket: source, target_ticket: target, relation_type: type) }
  end

  def queries(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == 'SCHEMA' || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  it 'answers the number of open tickets a ticket waits on' do
    waiter = ticket
    link(ticket, waiter)
    link(ticket, waiter, :precedes)

    expect(cache.preload([waiter]).fetch(waiter)).to eq(2)
  end

  it 'counts tickets, not edges: blocks and precedes from the same ticket are one' do
    waiter = ticket
    blocker = ticket
    link(blocker, waiter, :blocks)
    link(blocker, waiter, :precedes)

    expect(cache.preload([waiter]).fetch(waiter)).to eq(1)
  end

  it 'answers zero for a ticket that waits on nothing, preloaded or not' do
    lone = ticket
    expect(cache.preload([lone]).fetch(lone)).to eq(0)
    expect(described_class.new.fetch(ticket)).to eq(0)
  end

  it 'answers zero for a done ticket and ignores a done blocker' do
    done_waiter = ticket('Erledigt')
    link(ticket, done_waiter)
    waiter = ticket
    link(ticket('Erledigt'), waiter)

    expect(cache.preload([done_waiter, waiter]).fetch(done_waiter)).to eq(0)
    expect(cache.fetch(waiter)).to eq(0)
  end

  # The same status name means done in one project and open in the other. A blocker is judged
  # by its own project, whichever list shows the waiter.
  it 'judges a blocker from another project by that project' do
    other = new_project
    status_field(other, 'Offen' => 'is_new', 'Erledigt' => 'is_in_progress', 'Geprüft' => 'is_completed')
    waiter = ticket
    link(ticket('Erledigt', in_project: other), waiter)
    link(ticket('Geprüft', in_project: other), waiter)

    expect(cache.preload([waiter]).fetch(waiter)).to eq(1)
  end

  # Measured, not left to Prosopite: it only notices a repeated shape, and this test repeats
  # the one shape on purpose (plan §12, review 5).
  it 'counts a page in the same number of queries whatever its length' do
    small = Array.new(3) { ticket }
    large = Array.new(25) { ticket }
    link(ticket, large.last)

    counts = Prosopite.pause { [small, large].map { |page| queries { described_class.new.preload(page) } } }
    expect(counts.uniq.size).to eq(1)
    expect(counts.first).to be_positive
  end

  it 'asks nothing more for a ticket the preload has seen' do
    page = Array.new(3) { ticket }
    link(ticket, page.first)
    cache.preload(page)

    expect(queries { page.each { |row| cache.fetch(row) } }).to eq(0)
  end

  it 'counts a ticket the preload never saw on its own' do
    seen = ticket
    unseen = ticket
    link(ticket, unseen)
    cache.preload([seen])

    expect(cache.fetch(unseen)).to eq(1)
  end

  # Its twin answers an unsaved ticket with its empty entry; so does this, rather than raise.
  it 'answers zero for a ticket without an id, without asking' do
    expect(queries { expect(cache.fetch(Ticket.new)).to eq(0) }).to eq(0)
  end

  it 'asks nothing for an empty page' do
    expect(queries { cache.preload([]) }).to eq(0)
  end
end
