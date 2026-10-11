# frozen_string_literal: true

# A typed relation between two tickets of one organisation (doc/ticket_relations_plan.md,
# revision 4). Read path map for tickets: docs/architektur/tickets_lesepfad.md
#
# One row per relation. "Blocked by", "duplicated by" and "follows" are the same row read
# from its target: KINDS maps the seven labels a person can pick onto the four stored types,
# and Actors::CreateTicketRelation stores a backwards label flipped.
#
# Projects may differ, organisations may not. acts_as_tenant writes organisation_id from the
# CURRENT tenant, not from the tickets, so organisation_matches_tickets compares them.
#
# The waiting edges must stay free of cycles. That is no model rule: it needs a lock across
# the organisation, so Actors::CreateTicketRelation checks it with Tickets::CycleCheck. What
# "waits" means is answered by Tickets::Waiting alone.
#
# No history on purpose: no Trackable, no touch, no activity, no notification (plan §6.2).
# Activities are broadcast and served by the API without a reader, and a relation may point
# into a project the reader cannot see.
#
# == Schema Information
#
# Table name: ticket_relations
#
#  id               :uuid             not null, primary key
#  delay_days       :integer
#  relation_type    :integer          not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  organisation_id  :uuid             not null
#  source_ticket_id :uuid             not null
#  target_ticket_id :uuid             not null
#
# Indexes
#
#  index_ticket_relations_on_organisation_id    (organisation_id)
#  index_ticket_relations_on_source_and_type    (source_ticket_id,relation_type)
#  index_ticket_relations_on_target_and_type    (target_ticket_id,relation_type)
#  index_ticket_relations_single_edge_per_pair  (LEAST(source_ticket_id, target_ticket_id), GREATEST(source_ticket_id, target_ticket_id), relation_type) UNIQUE WHERE (relation_type = ANY (ARRAY[1, 2]))
#  index_ticket_relations_unique_edge           (source_ticket_id,target_ticket_id,relation_type) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (source_ticket_id => tickets.id) ON DELETE => cascade
#  fk_rails_...  (target_ticket_id => tickets.id) ON DELETE => cascade
#
class TicketRelation < ApplicationRecord
  # Before acts_as_tenant: acts_as_tenant 1.0.1 only checks the foreign ids of belongs_to
  # declared before it (CLAUDE.md, Multi-Tenancy).
  #
  # inverse_of: false on purpose. With has_many_inversing (load_defaults 7.2) an inverse here
  # puts a relation that is merely BUILT into the ticket's outgoing/incoming_relations, and it
  # stays there after a failed save; the next save of that ticket then writes it, past the lock
  # and the cycle check of Actors::CreateTicketRelation (review 30.09.2026). The has_many side
  # keeps its inverse, so ticket.outgoing_relations.build still sets the source.
  belongs_to :source_ticket, class_name: 'Ticket', inverse_of: false
  belongs_to :target_ticket, class_name: 'Ticket', inverse_of: false
  acts_as_tenant :organisation

  # Hash form with fixed integers: the partial unique index and the delay_days check spell
  # them out (spec/architecture/ticket_relation_schema_guard_spec.rb).
  enum :relation_type, { blocks: 0, relates_to: 1, duplicates: 2, precedes: 3 }, validate: true

  # Types where a pair carries at most ONE edge, in either direction: relates_to is symmetric
  # (A-B and B-A state the same fact), and the reverse of duplicates contradicts it. The
  # partial unique index enforces the same list.
  SINGLE_EDGE_TYPES = %w[relates_to duplicates].freeze

  # Edges that mean "the target waits for the source". Together they must stay acyclic
  # (Tickets::CycleCheck), and they are what Tickets::Waiting counts.
  WAITING_TYPES = %w[blocks precedes].freeze

  # The seven labels a person can pick. flipped: the label reads from the target's side,
  # so the other ticket becomes the source ("B is blocked by A" is stored as A blocks B).
  KINDS = {
    'blocks' => { relation_type: 'blocks', flipped: false },
    'blocked_by' => { relation_type: 'blocks', flipped: true },
    'relates_to' => { relation_type: 'relates_to', flipped: false },
    'duplicates' => { relation_type: 'duplicates', flipped: false },
    'duplicated_by' => { relation_type: 'duplicates', flipped: true },
    'precedes' => { relation_type: 'precedes', flipped: false },
    'follows' => { relation_type: 'precedes', flipped: true }
  }.freeze

  # The labels that carry a delay in days: precedes, read from either end.
  DELAY_KINDS = KINDS.select { |_, orientation| orientation[:relation_type] == 'precedes' }.keys.freeze

  # What the 4-byte integer column holds. Outside it, saving raises ActiveModel::RangeError
  # instead of failing the validation.
  DELAY_DAYS_RANGE = (-(2**31))..((2**31) - 1)

  # A saved relation keeps its ends and its type: the lock and the cycle check of
  # Actors::CreateTicketRelation guard the create only, and an update from relates_to to blocks
  # would close a cycle past both (review step 2, 30.09.2026). Another relation is removed and
  # created again. delay_days stays editable. Assigning raises (raise_on_assign_to_attr_readonly).
  attr_readonly :source_ticket_id, :target_ticket_id, :relation_type

  scope :waiting_edges, -> { where(relation_type: WAITING_TYPES) }

  # The relations of `ticket`, from either end. Arel, so the OR stays inside one condition and
  # a scope before it (visible_to) still applies to both halves.
  scope :touching, lambda { |ticket|
    where(arel_table[:source_ticket_id].eq(ticket.id).or(arel_table[:target_ticket_id].eq(ticket.id)))
  }

  # The relations `user` may see (plan §4), the one place of that rule: both ends are tickets
  # the user may read in `organisation` (TicketPolicy::Scope). A page only shows the relations
  # of a ticket its reader reads, so this is "the other ticket is readable"; nothing about a
  # ticket outside it (title, number, project) may reach the reader. Whether a ticket WAITS is
  # not narrowed by this (Tickets::Waiting counts every edge), only what is shown.
  #
  # token: narrows both ends further to the projects a personal access token reaches, for the
  # API and MCP: a person may read A and B while their token reaches A only (review 4).
  #
  # Built under `organisation` as the tenant, so the relation keeps that condition whatever
  # tenant is current when it runs. ⚠️ Not so a preload chained onto it (includes of the
  # tickets): that query runs at execution, under the tenant current THEN, and finds nothing
  # under another one. In a request both are the same; a job or an API caller with a token
  # runs it inside ActsAsTenant.with_tenant(organisation) (review round 4 of #944).
  def self.visible_to(user, organisation, token: nil)
    ActsAsTenant.with_tenant(organisation) do
      readable = TicketPolicy::Scope.new(user, Ticket).resolve
      if token
        reached = token.reach.project_ids_for(organisation.id)
        readable = readable.where(project_id: reached) unless reached.nil?
      end
      where(source_ticket_id: readable.select(:id), target_ticket_id: readable.select(:id))
    end
  end

  validate :not_self_referential
  validate :unique_edge
  validate :single_edge_per_pair
  validate :delay_only_for_precedes
  validate :organisation_matches_tickets
  validates :delay_days, numericality: { only_integer: true, in: DELAY_DAYS_RANGE }, allow_nil: true

  def waiting_edge?
    WAITING_TYPES.include?(relation_type)
  end

  # The ticket at the other end, seen from `ticket`.
  def other_ticket_for(ticket)
    source_ticket_id == ticket.id ? target_ticket : source_ticket
  end

  # The label of KINDS this relation carries on `ticket`'s page: the stored one on the source's
  # page, the flipped one on the target's. relates_to has no flipped label, it reads the same
  # from both ends.
  def kind_for(ticket)
    from_target = target_ticket_id == ticket.id
    kind, = KINDS.find { |_, orientation| orientation[:relation_type] == relation_type && orientation[:flipped] == from_target }
    kind || relation_type
  end

  private

  # By the tickets' CURRENT ids, which may be newer than the foreign key columns (a ticket
  # saved after the relation was built), and by object for two unsaved ends, whose ids are
  # still nil. Otherwise saving would create the ticket first and then run into the CHECK.
  def not_self_referential
    source_id = source_ticket&.id || source_ticket_id
    same_id = source_id.present? && source_id == (target_ticket&.id || target_ticket_id)
    same_record = !source_ticket.nil? && source_ticket.equal?(target_ticket)
    errors.add(:base, :self_reference) if same_id || same_record
  end

  def unique_edge
    return unless edge_complete?

    same = other_rows.where(source_ticket_id: source_ticket_id, target_ticket_id: target_ticket_id,
                            relation_type: relation_type)
    errors.add(:base, :duplicate) if same.exists?
  end

  # The same direction is unique_edge's case; this one only looks at the reverse.
  def single_edge_per_pair
    return unless edge_complete? && SINGLE_EDGE_TYPES.include?(relation_type)

    reverse = other_rows.where(source_ticket_id: target_ticket_id, target_ticket_id: source_ticket_id,
                               relation_type: relation_type)
    errors.add(:base, :reverse_exists) if reverse.exists?
  end

  def delay_only_for_precedes
    errors.add(:base, :delay_only_for_precedes) if !delay_days.nil? && !precedes?
  end

  # A missing organisation or ticket is the belongs_to validations' case.
  def organisation_matches_tickets
    return if organisation_id.nil?
    return if [source_ticket, target_ticket].compact.all? { |ticket| ticket.organisation_id == organisation_id }

    errors.add(:base, :organisation_mismatch)
  end

  def edge_complete?
    source_ticket_id.present? && target_ticket_id.present? && self.class.relation_types.key?(relation_type)
  end

  # The rows of THIS row's organisation, whatever tenant is current: the unique indexes know no
  # tenant either (review 30.09.2026). Since the ends and the type are read-only, no edit under
  # another tenant can reach this any more; it stays as the one scope these checks read, and
  # never one across all tenants. organisation_matches_tickets keeps both tickets in it.
  def other_rows
    self.class.unscoped.where(organisation_id: organisation_id).where.not(id: id)
  end
end
