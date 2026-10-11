# frozen_string_literal: true

require 'rails_helper'

# Reachability over a fixed edge set (doc/ticket_relations_plan.md, revision 4, §3.2). For a
# new waiting edge A -> B the question is: does B already reach A? These examples pin the
# direction, which edge types count, and that a cycle already in the data cannot make the
# query run forever.
RSpec.describe Tickets::CycleCheck do
  let(:organisation) { create(:organisation) }
  let(:projects) do
    ActsAsTenant.with_tenant(organisation) { create_list(:project, 3, organisation: organisation) }
  end
  let(:ticket_a) { create(:ticket, project: projects[0]) }
  let(:ticket_b) { create(:ticket, project: projects[1]) }
  let(:ticket_c) { create(:ticket, project: projects[2]) }
  let(:ticket_d) { create(:ticket, project: projects[0]) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def link(source, target, type)
    TicketRelation.create!(source_ticket: source, target_ticket: target, relation_type: type)
  end

  # Past the model, as rows written before any rule existed would be.
  def raw_link(source, target, type)
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, organisation.id, source.id, target.id, TicketRelation.relation_types.fetch(type.to_s)]))
      INSERT INTO ticket_relations (organisation_id, source_ticket_id, target_ticket_id, relation_type, created_at, updated_at)
      VALUES (?, ?, ?, ?, NOW(), NOW())
    SQL
  end

  def reaches?(from, to)
    described_class.call(edges: :waiting_relations, from: from.id, to: to.id)
  end

  it 'reaches nothing without edges' do
    expect(reaches?(ticket_a, ticket_b)).to be(false)
  end

  it 'follows an edge only from its source to its target' do
    link(ticket_a, ticket_b, :blocks)

    expect(reaches?(ticket_a, ticket_b)).to be(true)
    expect(reaches?(ticket_b, ticket_a)).to be(false)
  end

  it 'finds the two-cycle a new blocks edge would close (existing A blocks B, new B blocks A)' do
    link(ticket_a, ticket_b, :blocks)

    # New edge B -> A: does A already reach B?
    expect(reaches?(ticket_a, ticket_b)).to be(true)
  end

  it 'counts blocks and precedes together (existing A precedes B, new B blocks A)' do
    link(ticket_a, ticket_b, :precedes)

    expect(reaches?(ticket_a, ticket_b)).to be(true)
  end

  it 'finds a three-cycle across three projects' do
    link(ticket_a, ticket_b, :blocks)
    link(ticket_b, ticket_c, :precedes)

    # New edge C -> A closes A -> B -> C -> A.
    expect(reaches?(ticket_a, ticket_c)).to be(true)
    expect(reaches?(ticket_c, ticket_a)).to be(false)
  end

  it 'does not walk relates_to or duplicates, they are no waiting edges' do
    link(ticket_a, ticket_b, :relates_to)
    link(ticket_b, ticket_c, :duplicates)

    expect(reaches?(ticket_a, ticket_b)).to be(false)
    expect(reaches?(ticket_a, ticket_c)).to be(false)
  end

  it 'stops at a non-waiting edge in the middle of a chain' do
    link(ticket_a, ticket_b, :blocks)
    link(ticket_b, ticket_c, :relates_to)

    expect(reaches?(ticket_a, ticket_c)).to be(false)
  end

  it 'ends on a cycle already in the data, also when the target is out of reach' do
    raw_link(ticket_a, ticket_b, :blocks)
    raw_link(ticket_b, ticket_c, :precedes)
    raw_link(ticket_c, ticket_a, :blocks)
    ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = '2s'")

    expect(reaches?(ticket_a, ticket_d)).to be(false)
    expect(reaches?(ticket_b, ticket_a)).to be(true)
  end

  it 'accepts only an edge set from its own list, never SQL from outside' do
    expect { described_class.call(edges: 'SELECT 1', from: ticket_a.id, to: ticket_b.id) }.to raise_error(KeyError)
    expect(described_class::EDGES.keys).to eq([:waiting_relations])
  end
end
