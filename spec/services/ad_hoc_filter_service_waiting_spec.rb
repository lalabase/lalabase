# frozen_string_literal: true

require 'rails_helper'

# The bar's two waiting filters, "Wartet" (waiting on an open ticket) and "Hält auf" (holds
# others up), each with "ist" and "ist nicht" (doc/ticket_relations_plan.md, revision 4, §9).
# What "waits" means is Tickets::Waiting's (spec/services/tickets/waiting_spec.rb holds the
# cases); this spec holds the wiring: the right ticket set, the negation, the combination with
# other conditions, the models the category exists for, and a query count that does not grow
# with the list.
RSpec.describe AdHocFilterService do
  let(:organisation) { create(:organisation) }
  let(:project) { new_project }
  let(:other_project) { new_project }

  before do
    ActsAsTenant.current_tenant = organisation
    [project, other_project].each { |each_project| status_field(each_project) }
  end

  after { ActsAsTenant.current_tenant = nil }

  def new_project
    create(:project, organisation: organisation)
  end

  def status_field(in_project)
    create(:ticket_attribute_definition,
           project: in_project, name: 'status', field_type: 'select', system: true,
           options: { 'allowed_values' => [
             { 'value' => 'Offen', 'labels' => { 'de' => 'Offen' }, 'system_functions' => ['is_new'] },
             { 'value' => 'In Arbeit', 'labels' => { 'de' => 'In Arbeit' }, 'system_functions' => ['is_in_progress'] },
             { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] }
           ] })
  end

  def ticket(status = 'Offen', in_project: project)
    Prosopite.pause { create(:ticket, project: in_project, custom_attributes: { 'status' => status }) }
  end

  def link(source, target, type = :blocks)
    Prosopite.pause { TicketRelation.create!(source_ticket: source, target_ticket: target, relation_type: type) }
  end

  def ids(filters, operators = {}, query: project.tickets)
    described_class.new(project, filters, operators).apply(query).pluck(:id)
  end

  # blocker -> waiter (blocks), first -> second (precedes), a done blocker in front of done_waiter,
  # a done ticket that would wait, and a ticket without any relation.
  let!(:blocker) { ticket }
  let!(:waiter) { ticket('In Arbeit') }
  let!(:first) { ticket }
  let!(:second) { ticket }
  let!(:done_blocker) { ticket('Erledigt') }
  let!(:freed) { ticket }
  let!(:done_waiter) { ticket('Erledigt') }
  let!(:plain) { ticket }
  let(:everything) { [blocker, waiter, first, second, done_blocker, freed, done_waiter, plain].map(&:id) }

  before do
    link(blocker, waiter)
    link(first, second, :precedes)
    link(done_blocker, freed)
    link(blocker, done_waiter)
  end

  describe 'waiting' do
    it "'ist' keeps the open tickets that wait on an open ticket, through blocks and precedes" do
      expect(ids({ 'waiting' => ['true'] })).to contain_exactly(waiter.id, second.id)
    end

    it "'ist nicht' keeps every other ticket of the list, the done ones included" do
      expect(ids({ 'waiting' => ['true'] }, { 'waiting' => 'not' }))
        .to match_array(everything - [waiter.id, second.id])
    end
  end

  describe 'blocking' do
    it "'ist' keeps the open tickets an open ticket waits on" do
      expect(ids({ 'blocking' => ['true'] })).to contain_exactly(blocker.id, first.id)
    end

    it "'ist nicht' keeps every other ticket of the list, the done ones included" do
      expect(ids({ 'blocking' => ['true'] }, { 'blocking' => 'not' }))
        .to match_array(everything - [blocker.id, first.id])
    end
  end

  it 'combines with a status and a tag condition (AND)' do
    tag = create(:tag, name: 'kunde', organisation: organisation)
    [waiter, second].each { |each_ticket| Prosopite.pause { create(:tagging, tag: tag, taggable: each_ticket) } }

    expect(ids({ 'waiting' => ['true'], 'status' => ['Offen'], 'tag' => ['kunde'] })).to eq([second.id])
    expect(ids({ 'waiting' => ['true'], 'status' => ['Offen'] }, { 'waiting' => 'not' }))
      .to contain_exactly(blocker.id, first.id, freed.id, plain.id)
  end

  it 'combines both states: holds others up and does not wait' do
    head = ticket
    link(head, first)

    expect(ids({ 'blocking' => ['true'], 'waiting' => ['true'] }, { 'waiting' => 'not' }))
      .to contain_exactly(blocker.id, head.id)
  end

  it 'only narrows the list it is given: a blocker outside it never joins the answer' do
    outside = ticket(in_project: other_project)
    link(outside, plain)

    expect(ids({ 'waiting' => ['true'] })).to contain_exactly(waiter.id, second.id, plain.id)
    expect(ids({ 'blocking' => ['true'] })).to contain_exactly(blocker.id, first.id)
  end

  it 'ignores a value the bar never offers instead of filtering on it' do
    expect(ids({ 'waiting' => ['false'] })).to match_array(everything)
    expect(ids({ 'blocking' => ['yes'] }, { 'blocking' => 'not' })).to match_array(everything)
  end

  it 'leaves notes, documents and meetings alone: the states belong to tickets' do
    records = Prosopite.pause do
      { Note => create(:note, project: project), Document => create(:document, project: project),
        Meeting => create(:meeting, project: project) }
    end
    service = described_class.new(project, { 'waiting' => ['true'], 'blocking' => ['true'] }, { 'waiting' => 'not' })

    records.each do |model, record|
      expect(service.apply(model.where(project: project)).pluck(:id)).to eq([record.id]), model.name
    end
  end

  it 'names the condition for the chip in the current locale' do
    metadata = described_class.new(project, { 'waiting' => ['true'], 'blocking' => ['true'] }).active_filters_metadata

    expect(metadata['waiting']).to eq([{ value: 'true', label: I18n.t('views.organisations.tickets.index.filter_waiting') }])
    expect(metadata['blocking']).to eq([{ value: 'true', label: I18n.t('views.organisations.tickets.index.filter_blocking') }])
  end

  # The filter runs on the whole filtered list before the page is cut. Its cost may not grow with
  # the number of tickets: the done values are one preparation query, the rest is subqueries.
  describe 'query count' do
    def queries_for(filters, operators = {})
      count = 0
      counter = lambda do |*, payload|
        count += 1 unless payload[:name] == 'SCHEMA' || payload[:cached]
      end
      # The same filter runs repeatedly on purpose, which Prosopite would read as N+1.
      Prosopite.pause do
        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
          described_class.new(project, filters, operators).apply(project.tickets).to_a
        end
      end
      count
    end

    def counts_for_each_case
      [
        [{ 'waiting' => ['true'] }, {}], [{ 'waiting' => ['true'] }, { 'waiting' => 'not' }],
        [{ 'blocking' => ['true'] }, {}], [{ 'blocking' => ['true'] }, { 'blocking' => 'not' }]
      ].map { |filters, operators| queries_for(filters, operators) }
    end

    it 'is the same for 8 and for 30 tickets' do
      few = counts_for_each_case
      11.times { link(ticket, ticket) }

      expect(project.tickets.count).to eq(30)
      expect(counts_for_each_case).to eq(few)
    end
  end
end
