# frozen_string_literal: true

# What the "Relations" section and the waiting hint of one ticket show
# (doc/ticket_relations_plan.md, revision 4, §8.1 and §8.2), read once for both.
#
# Rows: only the relations the reader may see (TicketRelation.visible_to), grouped from this
# ticket's side in GROUPS order; within a group the open counterparts first, done ones last.
# "Done" and "waits" come from Tickets::Waiting alone, never from a status compared here.
#
# Hint: whether this ticket waits counts EVERY open blocker (Tickets::Waiting.for), readable or
# not, since waiting is a fact about this ticket. What it names is limited to the readable ones;
# the rest is a count "without access", with no title, number or project.
#
# A fixed number of queries whatever the number of relations: the relations with both ends and
# their projects, the open ids, the status definitions of the projects involved, the blockers.
#
# Entry point: for
module Tickets
  class RelationSection
    GROUPS = %w[waiting_on holding_up related duplicates].freeze

    # Every label of TicketRelation::KINDS, read from this ticket's side, and its group.
    GROUP_OF_KIND = {
      'blocked_by' => 'waiting_on',
      'follows' => 'waiting_on',
      'blocks' => 'holding_up',
      'precedes' => 'holding_up',
      'relates_to' => 'related',
      'duplicates' => 'duplicates',
      'duplicated_by' => 'duplicates'
    }.freeze

    Entry = Data.define(:relation, :kind, :ticket, :open, :status_definition) do
      def done? = !open

      # Shown only when set and not zero (plan §3.1); it is stored, never calculated with.
      def delay_days
        days = relation.delay_days
        days unless days.nil? || days.zero?
      end

      def status_label
        value = ticket.get_custom_attribute('status')
        return if value.blank?

        status_definition&.display_value(value) || value
      end
    end

    # single: one readable blocker, named. several: readable blockers only, counted.
    # hidden: blockers without access only. mixed: both, counted, with the hidden share.
    Hint = Data.define(:state, :blockers, :total, :hidden)

    def self.for(ticket:, user:, organisation:)
      new(ticket: ticket, user: user, organisation: organisation)
    end

    def initialize(ticket:, user:, organisation:)
      @ticket = ticket
      @user = user
      @organisation = organisation
    end

    delegate :any?, to: :entries

    # [[group, [Entry, ...]], ...] for the groups that have rows, in GROUPS order.
    def groups
      @groups ||= entries.group_by { |entry| GROUP_OF_KIND.fetch(entry.kind) }
                         .sort_by { |group, _| GROUPS.index(group) }
                         .map { |group, rows| [group, rows.sort_by { |row| [row.done? ? 1 : 0, row.ticket.number, row.ticket.id] }] }
    end

    # nil when this ticket waits on nothing.
    def hint
      return @hint if defined?(@hint)

      blocker_ids = Tickets::Waiting.for(@ticket).pluck(:id)
      @hint = blocker_ids.empty? ? nil : build_hint(blocker_ids)
    end

    private

    def entries
      @entries ||= begin
        relations = TicketRelation.visible_to(@user, @organisation).touching(@ticket)
                                  .includes(source_ticket: :project, target_ticket: :project).to_a
        others = relations.map { |relation| relation.other_ticket_for(@ticket) }
        open = Tickets::Waiting.open_ids(others.map(&:id).uniq).to_set
        statuses = status_definitions(others.map(&:project_id).uniq)
        relations.zip(others).map do |relation, other|
          Entry.new(relation: relation, kind: relation.kind_for(@ticket), ticket: other,
                    open: open.include?(other.id), status_definition: statuses[other.project_id])
        end
      end
    end

    def status_definitions(project_ids)
      return {} if project_ids.empty?

      TicketAttributeDefinition.where(project_id: project_ids, name: 'status', active: true).index_by(&:project_id)
    end

    # A blocker linked twice (blocks and precedes) is one ticket, as in Tickets::Waiting.
    def build_hint(blocker_ids)
      readable = entries.select { |entry| blocker_ids.include?(entry.ticket.id) }.map(&:ticket).uniq(&:id)
      hidden = blocker_ids.size - readable.size
      state = if hidden.zero? then readable.one? ? :single : :several
              elsif readable.empty? then :hidden
              else :mixed
              end
      Hint.new(state: state, blockers: readable, total: blocker_ids.size, hidden: hidden)
    end
  end
end
