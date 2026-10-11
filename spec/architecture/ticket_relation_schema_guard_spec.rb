# frozen_string_literal: true

require 'rails_helper'

# Guard: two rules of TicketRelation live twice, once as a Ruby constant and once as
# integers inside the database schema (doc/ticket_relations_plan.md, revision 4, §3.1):
#
#   1. SINGLE_EDGE_TYPES (one edge per pair, either direction) is the predicate of the
#      partial unique index on (LEAST, GREATEST, relation_type).
#   2. "delay_days only on precedes" is a CHECK that names the integer of precedes.
#
# A new type in the constant, or a renumbered enum, would leave the database enforcing the
# old rule without a word. Both are read from the catalogue as PostgreSQL stores them:
# `IN (1, 2)` comes back normalised as `(relation_type = ANY (ARRAY[1, 2]))`, so the
# expectation is built in exactly that form from the model. A naive comparison with
# "IN (1,2)" would be red on day one, and loosening it would leave a guard that guards
# nothing. Each rule therefore carries a counterproof against a deliberately wrong
# definition, created inside the example's transaction and rolled back with it.
RSpec.describe 'TicketRelation schema guard' do
  let(:connection) { ActiveRecord::Base.connection }

  def relation_type_integers(types)
    TicketRelation.relation_types.values_at(*types)
  end

  # The form pg_get_expr gives for `relation_type IN (...)`.
  def canonical_single_edge_predicate(types)
    "(relation_type = ANY (ARRAY[#{relation_type_integers(types).join(', ')}]))"
  end

  # The form pg_get_constraintdef gives for `delay_days IS NULL OR relation_type = n`.
  def canonical_delay_check(integer)
    "CHECK (((delay_days IS NULL) OR (relation_type = #{integer})))"
  end

  def index_predicate(name)
    connection.select_value(<<~SQL.squish, 'SCHEMA', [name])
      SELECT pg_get_expr(i.indpred, i.indrelid)
      FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = $1
    SQL
  end

  # The key columns in order, one entry per column as PostgreSQL prints it. Comparing the whole
  # list catches a missing and an extra key; a substring search over the definition did not,
  # because relation_type also appears in the predicate (review 30.09.2026).
  def index_keys(name)
    connection.select_values(<<~SQL.squish, 'SCHEMA', [name])
      SELECT pg_get_indexdef(i.indexrelid, k, true)
      FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      CROSS JOIN generate_series(1, i.indnatts) AS k
      WHERE c.relname = $1
      ORDER BY k
    SQL
  end

  def unique_index?(name)
    connection.select_value(<<~SQL.squish, 'SCHEMA', [name])
      SELECT i.indisunique FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE c.relname = $1
    SQL
  end

  def check_definition(name)
    connection.select_value(<<~SQL.squish, 'SCHEMA', [name])
      SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1 AND contype = 'c'
    SQL
  end

  describe 'one edge per pair (SINGLE_EDGE_TYPES)' do
    let(:index_name) { 'index_ticket_relations_single_edge_per_pair' }

    let(:pair_keys) do
      ['LEAST(source_ticket_id, target_ticket_id)', 'GREATEST(source_ticket_id, target_ticket_id)', 'relation_type']
    end

    it 'is a unique index over exactly the unordered pair and the type' do
      expect(unique_index?(index_name)).to be(true)
      expect(index_keys(index_name)).to eq(pair_keys)
    end

    it 'would notice a missing or an extra key (counterproof against the catalogue)' do
      connection.execute(<<~SQL.squish)
        CREATE UNIQUE INDEX guard_counterproof_missing_type ON ticket_relations
          (LEAST(source_ticket_id, target_ticket_id), GREATEST(source_ticket_id, target_ticket_id))
          WHERE relation_type IN (1, 2)
      SQL
      connection.execute(<<~SQL.squish)
        CREATE UNIQUE INDEX guard_counterproof_extra_key ON ticket_relations
          (LEAST(source_ticket_id, target_ticket_id), GREATEST(source_ticket_id, target_ticket_id), relation_type, id)
          WHERE relation_type IN (1, 2)
      SQL

      expect(index_keys('guard_counterproof_missing_type')).to eq(pair_keys.first(2))
      expect(index_keys('guard_counterproof_extra_key')).to eq(pair_keys + ['id'])
    end

    it 'has exactly the predicate built from SINGLE_EDGE_TYPES' do
      expect(index_predicate(index_name)).to eq(canonical_single_edge_predicate(TicketRelation::SINGLE_EDGE_TYPES))
    end

    it 'would notice a type added to the constant' do
      grown = TicketRelation::SINGLE_EDGE_TYPES + ['precedes']

      expect(index_predicate(index_name)).not_to eq(canonical_single_edge_predicate(grown))
    end

    it 'would notice an index with a different predicate (counterproof against the catalogue)' do
      connection.execute(<<~SQL.squish)
        CREATE UNIQUE INDEX guard_counterproof_single_edge ON ticket_relations
          (LEAST(source_ticket_id, target_ticket_id), GREATEST(source_ticket_id, target_ticket_id), relation_type)
          WHERE relation_type IN (1, 3)
      SQL

      counterproof = index_predicate('guard_counterproof_single_edge')

      expect(counterproof).to eq('(relation_type = ANY (ARRAY[1, 3]))')
      expect(counterproof).not_to eq(canonical_single_edge_predicate(TicketRelation::SINGLE_EDGE_TYPES))
    end
  end

  describe 'delay only on precedes' do
    let(:check_name) { 'ticket_relations_delay_only_for_precedes' }

    it 'names the integer of precedes' do
      expect(check_definition(check_name)).to eq(canonical_delay_check(TicketRelation.relation_types.fetch('precedes')))
    end

    it 'would notice a renumbered precedes' do
      renumbered = TicketRelation.relation_types.values.max + 1

      expect(check_definition(check_name)).not_to eq(canonical_delay_check(renumbered))
    end

    it 'would notice a check on another type (counterproof against the catalogue)' do
      connection.execute(<<~SQL.squish)
        ALTER TABLE ticket_relations ADD CONSTRAINT guard_counterproof_delay
          CHECK (delay_days IS NULL OR relation_type = 2)
      SQL

      counterproof = check_definition('guard_counterproof_delay')

      expect(counterproof).to eq(canonical_delay_check(2))
      expect(counterproof).not_to eq(canonical_delay_check(TicketRelation.relation_types.fetch('precedes')))
    end
  end
end
