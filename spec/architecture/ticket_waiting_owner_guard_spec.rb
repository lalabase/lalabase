# frozen_string_literal: true

require 'rails_helper'

# Guard: "waits" has one owner, and relations have one way in (doc/ticket_relations_plan.md,
# revision 4, §5.3 and §6.1).
#
# Seven places need the state: the ticket header, the list column, the board, the phone row,
# both filter systems and the API. Built by hand seven times, the versions drift apart, and
# the likely drift is the one §5.2 is about: "done" pooled over all projects instead of judged
# per project at both ends of an edge. So outside the owners below no code names the table in
# SQL, the waiting edge set, or a relation type as a query key. Everyone else calls
# Tickets::Waiting.
#
# Writing goes through Actors::CreateTicketRelation / DestroyTicketRelation only: the create
# holds the lock and runs the cycle check, and a relation written anywhere else skips both
# (review step 2, 30.09.2026). The ends and the type of a saved relation are read-only in the
# model for the same reason.
#
# A tripwire, not a parser: it matches source text. Reading the relations of a ticket for
# display is fine; filtering them down to blocks/precedes is the waiting question.
#
# The exception list starts empty and may only shrink. A new entry names its file and why it
# cannot ask Tickets::Waiting.
module TicketWaitingOwnerGuard
  # Ticket is not on the list: its two associations name no waiting type, and a hand-built
  # scope such as `blocked` would most likely appear there.
  OWNERS = %w[
    app/models/ticket_relation.rb
    app/services/tickets/waiting.rb
    app/services/tickets/cycle_check.rb
    app/services/actors/create_ticket_relation.rb
    app/services/actors/destroy_ticket_relation.rb
  ].freeze

  EXCEPTIONS = {}.freeze

  PATTERNS = {
    # SQL forms only: the plan names flash keys, partials and ids after the table as well.
    'the ticket_relations table in SQL' =>
      /\b(?:FROM|JOIN)\s+"?ticket_relations\b|\bfrom\(\s*["':]*ticket_relations|"ticket_relations"\.|
       \bArel::Table\.new\(\s*["':]*ticket_relations/xi,
    'the waiting edge set' => /\bWAITING_TYPES\b|\bwaiting_edges\b/,
    'a relation type as a query or write key' => /\brelation_type:|['"]relation_type['"]\s*=>/,
    'a waiting type on the relation associations' => /\b(?:incoming|outgoing)_relations\b.*\b(?:blocks|precedes)\b/,
    'a waiting type straight on TicketRelation' => /\bTicketRelation\.(?:blocks|precedes|not_blocks|not_precedes)\b/,
    'a relation written outside the two actors' =>
      /\bTicketRelation\.(?:new|create!?|insert(?:_all)?!?|upsert(?:_all)?|find_or_create_by!?|create_or_find_by!?)\b|
       \b(?:incoming|outgoing)_relations\.(?:new|build|create!?)\b/x
  }.freeze

  SOURCES = 'app/**/*.{rb,erb,js,jbuilder}'
  LIB_SOURCES = 'lib/**/*.{rb,rake}'

  module_function

  def offences(source)
    source.each_line.with_index(1).flat_map do |line, number|
      next [] if line.lstrip.start_with?('#')

      PATTERNS.filter_map { |name, pattern| "#{number}: #{name}" if line.match?(pattern) }
    end
  end

  def files
    [SOURCES, LIB_SOURCES].flat_map { |glob| Dir[Rails.root.join(glob)] }
                          .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
                          .sort
  end
end

RSpec.describe 'Ticket waiting owner guard' do
  guard = TicketWaitingOwnerGuard

  it 'finds source files to read at all' do
    expect(guard.files.size).to be > 500
  end

  it 'names owners that exist' do
    missing = guard::OWNERS.reject { |path| Rails.root.join(path).exist? }

    expect(missing).to be_empty, "Owner moved or renamed, update the list: #{missing.join(', ')}"
  end

  it 'finds no waiting query outside the owners' do
    found = (guard.files - guard::OWNERS - guard::EXCEPTIONS.keys)
            .index_with { |path| guard.offences(File.read(Rails.root.join(path))) }
            .reject { |_, offences| offences.empty? }

    expect(found).to be_empty, <<~MSG
      Built by hand outside Tickets::Waiting:
      #{found.map { |path, offences| "  #{path}\n    #{offences.join("\n    ")}" }.join("\n")}
      Ask Tickets::Waiting (waiting, blocking, counts_for, for) instead.
    MSG
  end

  it 'keeps no exception that is not needed any more' do
    unneeded = guard::EXCEPTIONS.keys.select do |path|
      !Rails.root.join(path).exist? || guard.offences(File.read(Rails.root.join(path))).empty?
    end

    expect(unneeded).to be_empty
  end

  describe 'detection logic (synthetic sources)' do
    it 'flags the table in SQL, the edge set and waiting types on the associations' do
      expect(guard.offences(%(Ticket.joins("JOIN ticket_relations r ON r.target_ticket_id = tickets.id")))).not_to be_empty
      expect(guard.offences('TicketRelation.where(relation_type: TicketRelation::WAITING_TYPES)')).not_to be_empty
      expect(guard.offences('TicketRelation.waiting_edges.where(target_ticket: ticket)')).not_to be_empty
      expect(guard.offences('ticket.incoming_relations.blocks.exists?')).not_to be_empty
      expect(guard.offences("ticket.outgoing_relations.where(relation_type: 'precedes')")).not_to be_empty
      expect(guard.offences('TicketRelation.precedes.count')).not_to be_empty
    end

    # Review step 2 (30.09.2026): the most likely hand-built forms went unnoticed.
    it 'flags a relation type as a query or write key, however it is spelled' do
      expect(guard.offences('TicketRelation.where(relation_type: %w[blocks precedes], target_ticket: t)')).not_to be_empty
      expect(guard.offences('scope.where(relation_type: :blocks)')).not_to be_empty
      expect(guard.offences('relations.where(relation_type: [0, 3])')).not_to be_empty
      expect(guard.offences("  .where('relation_type' => 3)")).not_to be_empty
    end

    it 'flags writing a relation outside the two actors' do
      expect(guard.offences('TicketRelation.create!(source_ticket: a, target_ticket: b)')).not_to be_empty
      expect(guard.offences('TicketRelation.new(source_ticket: a)')).not_to be_empty
      expect(guard.offences('TicketRelation.insert_all(rows)')).not_to be_empty
      expect(guard.offences('ticket.outgoing_relations.create!(target_ticket: b)')).not_to be_empty
      expect(guard.offences('ticket.incoming_relations.build(source_ticket: b)')).not_to be_empty
    end

    it 'flags the table only in its SQL forms' do
      expect(guard.offences("connection.select_all('SELECT * FROM ticket_relations WHERE x')")).not_to be_empty
      expect(guard.offences('where(\'"ticket_relations"."target_ticket_id" = tickets.id\')')).not_to be_empty
      expect(guard.offences("Ticket.from('ticket_relations')")).not_to be_empty
      expect(guard.offences('Arel::Table.new(:ticket_relations)')).not_to be_empty
    end

    # Review round 3 (30.09.2026): the plan puts the flash messages under
    # flash.ticket_relations.*, and PR 2 renders partials and ids of that name.
    it 'leaves the name alone where it is no SQL' do
      expect(guard.offences("flash[:notice] = t('flash.ticket_relations.created')")).to be_empty
      expect(guard.offences("render 'organisations/tickets/ticket_relations', ticket: @ticket")).to be_empty
      expect(guard.offences('dom_id(@ticket, :ticket_relations)')).to be_empty
    end

    it 'leaves reading relations for display, the owner and comments alone' do
      expect(guard.offences('ticket.incoming_relations.includes(:source_ticket)')).to be_empty
      expect(guard.offences("t(\".kinds.\#{relation.relation_type}\")")).to be_empty
      expect(guard.offences('relation.waiting_edge? ? :wait : :other')).to be_empty
      expect(guard.offences('Tickets::Waiting.counts_for(ids)')).to be_empty
      expect(guard.offences('  # ticket_relations are counted by Tickets::Waiting')).to be_empty
    end

    it 'reads ticket.rb as well: its associations name no waiting type' do
      expect(guard::OWNERS).not_to include('app/models/ticket.rb')
    end
  end
end
