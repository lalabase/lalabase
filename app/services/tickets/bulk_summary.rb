# frozen_string_literal: true

# What the selected tickets hold today, per field the panel can change
# (doc/ticket_bulk_edit_plan.md, slice 4; designer template 29a: "der Bestand
# ist Pflicht"). The stock line under every change row is built from this:
# "bisher: in Arbeit 8 · offen 6", "3 ohne Frist, 11 verschieden". Every number
# comes from the living selection, never from a constant, and the digest per
# field is the fingerprint the execute step sends back (D11): a run that finds
# a different stock than the reader saw writes nothing.
#
# A handful of GROUP BY queries over at most BulkSelection::MAX_TICKETS ids.
#
# Entry point: call
module Tickets
  class BulkSummary
    def self.call(project:, ticket_ids:, fields:)
      new(project: project, ticket_ids: ticket_ids, fields: fields).call
    end

    def initialize(project:, ticket_ids:, fields:)
      @project = project
      @ticket_ids = Array(ticket_ids)
      @fields = fields
    end

    def call
      {
        count: @ticket_ids.size,
        fields: @fields.to_h { |field| [field.key, summary_for(field)] }
      }
    end

    private

    def summary_for(field)
      data = case field.kind
             when 'single' then single(field)
             when 'boolean' then boolean(field)
             when 'date' then date(field)
             when 'multi' then multi(field)
             else {}
             end
      data.merge(digest: digest(data))
    end

    # A multi-valued field: how many of the selected tickets carry each value
    # (a value nobody carries is simply absent). Tags, assignees and watchers
    # are associations, a multiselect is an array in the JSONB.
    def multi(field)
      counts = case field.key
               when BulkFields::TAGS
                 Tagging.joins(:tag).where(taggable_type: 'Ticket', taggable_id: @ticket_ids).group('tags.name').count
               when BulkFields::ASSIGNEES
                 TicketAssignment.where(ticket_id: @ticket_ids).group(:user_id).count
               when BulkFields::WATCHERS
                 NotificationSubscription.where(subscribable_type: 'Ticket', subscribable_id: @ticket_ids, mode: 'follow')
                                         .group(:user_id).count
               else
                 multiselect_counts(field.key)
               end
      labels = field.options.to_h { |option| [option[:value].to_s, option[:label]] }
      labels.merge!(people_labels(counts.keys.map(&:to_s) - labels.keys)) if PEOPLE.include?(field.key)
      values = counts.map { |value, count| { value: value.to_s, label: labels.fetch(value.to_s, value.to_s), count: count } }
                     .sort_by { |entry| [-entry[:count], entry[:value]] }
      { values: values }
    end

    PEOPLE = [BulkFields::ASSIGNEES, BulkFields::WATCHERS].freeze

    # A person on the tickets who is no longer offered (deactivated, or without
    # a membership) keeps a name. Every person on the selection is read once,
    # for both people fields.
    def people_labels(ids)
      return {} if ids.empty?

      @people_names ||= User.where(id: TicketAssignment.where(ticket_id: @ticket_ids).select(:user_id))
                            .or(User.where(id: NotificationSubscription.where(subscribable_type: 'Ticket', subscribable_id: @ticket_ids)
                                                                       .select(:user_id)))
                            .to_h { |user| [user.id.to_s, user.display_name] }
      @people_names.slice(*ids)
    end

    def multiselect_counts(key)
      scope.pluck(Arel.sql("custom_attributes->#{Ticket.connection.quote(key)}"))
           .flat_map { |value| Array(value) }
           .map(&:to_s).reject(&:blank?).tally
    end

    # A select: how many carry each value, how many none.
    def single(field)
      counts = scope.group(value_sql(field.key)).count
      without = counts.delete(nil).to_i + counts.delete('').to_i
      labels = field.options.to_h { |option| [option[:value], option[:label]] }
      values = counts.map { |value, count| { value: value, label: labels.fetch(value, value), count: count } }
                     .sort_by { |entry| [-entry[:count], entry[:value].to_s] }
      { values: values, without: without }
    end

    def boolean(field)
      raw = scope.pluck(value_sql(field.key)).map(&:to_s)
      yes = raw.count { |value| %w[true 1 t].include?(value) }
      without = raw.count(&:blank?)
      { yes: yes, no: raw.size - yes - without, without: without }
    end

    # A date: how many have none, how many different ones, and the one date
    # when every ticket carries the same.
    def date(field)
      raw = scope.pluck(value_sql(field.key)).map(&:to_s)
      dates = raw.reject(&:blank?)
      distinct = dates.uniq
      { without: raw.size - dates.size, distinct: distinct.size, only: (distinct.size == 1 && dates.size == raw.size ? distinct.first : nil) }
    end

    def value_sql(key)
      Arel.sql("custom_attributes->>#{Ticket.connection.quote(key)}")
    end

    def scope
      @scope ||= @project.tickets.where(id: @ticket_ids)
    end

    def digest(data)
      Digest::SHA256.hexdigest(data.to_json)[0, 16]
    end
  end
end
