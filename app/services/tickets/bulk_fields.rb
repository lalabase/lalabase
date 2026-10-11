# frozen_string_literal: true

# The fields a bulk change may set in a project, in the groups and kinds of the
# panel (doc/ticket_bulk_edit_plan.md, slices 4 and 5; designer template 29a
# §5). One owner for "what can be changed": the shell renders its picker and
# its row templates from this list, the summary computes a stock line for
# every entry, and the change registry (slice 6) validates against it, so the
# panel and the server can never disagree on what is offered.
#
# Groups: "ticket" holds the project's own fields (status, priority, the
# deadline) and the tags, "people" the assignees and the watchers, "custom"
# every other active definition. Kinds name the control, not the storage:
# "single" (a select), "multi" (a multiselect, tags, people: plus and minus
# per value, D7), "date", "boolean". Text fields are never offered (the
# template has no control for free text), and nothing computed.
#
# Entry point: for
module Tickets
  class BulkFields
    # `definition` is the attribute definition behind a project field, nil for
    # the three association fields: a change that must ask the definition
    # (a clear of a required select) asks it through the field. `creatable`
    # marks the one field that takes a value nobody has made yet (a new tag):
    # the panel offers the typed name, the change accepts it.
    # `removable` (people fields only): values a change may REMOVE beyond `options`,
    # with their labels: every member of the organisation (deactivated ones
    # included) and whoever is on the tickets of the change (assigned, or with
    # any subscription), also after their membership was deleted. A person
    # assigned while they had access stays on the ticket after losing it; the
    # head menu (which shows them ticked) and the terminal must be able to take
    # them off (plan 9.7 of the terminal client S2). A lambda, read through
    # #removable_options only when a change removes somebody outside `options`:
    # a status change never pays for it.
    Field = Struct.new(:key, :label, :group, :kind, :options, :definition, :creatable, :removable,
                       keyword_init: true) do
      def removable_options
        @removable_options ||= removable.respond_to?(:call) ? removable.call : Array(removable)
      end
    end

    GROUPS = %w[ticket people custom].freeze
    KINDS = %w[single multi date boolean].freeze
    KIND_BY_FIELD_TYPE = {
      'select' => 'single', 'multiselect' => 'multi', 'date' => 'date', 'checkbox' => 'boolean'
    }.freeze
    # The three fields that are associations, not attributes; their keys are
    # reserved and can never collide with a definition's name (a definition
    # named "tags" would be a project's own attribute and is skipped).
    TAGS = 'tags'
    ASSIGNEES = 'assignees'
    WATCHERS = 'watchers'
    ASSOCIATION_KEYS = [TAGS, ASSIGNEES, WATCHERS].freeze

    # `user` is whoever reads or runs the change: the tags offered are the ones
    # TagPolicy lets that user see. `ticket_ids`: the tickets a change will
    # touch, so the people on them are removable (Field#removable).
    def self.for(project:, user:, locale: I18n.locale, name_mode: User::PreferenceStore::NAME_DISPLAY_DEFAULT,
                 ticket_ids: [])
      new(project: project, user: user, locale: locale, name_mode: name_mode, ticket_ids: ticket_ids).call
    end

    # The catalogue a recorded run is read back through (its undo, its result
    # line). The tag names the run itself names stay offered: they were
    # offered when the run was made, and a removal that took a tag off its
    # last tickets in the reader's projects has since hidden it from
    # TagPolicy::Scope. Nothing else is widened.
    # The people the run named stay offered for its undo too, read from the run
    # itself: they were valid when it was made, and a person deactivated or
    # without a membership since is no longer offered anywhere else. The undo
    # takes a person the run added off again; a person the run removed it does
    # not put back if they may not be assigned any more (AddRemoveBase#restorable).
    def self.for_run(run:, user:, locale: I18n.locale, name_mode: User::PreferenceStore::NAME_DISPLAY_DEFAULT)
      self.for(project: run.project, user: user, locale: locale, name_mode: name_mode).map do |field|
        recorded = recorded_values(run, field.key)
        case field.key
        when TAGS then with_options(field, recorded)
        when ASSIGNEES, WATCHERS then with_people(field, recorded, name_mode)
        else field
        end
      end
    end

    def self.recorded_values(run, key)
      Array(run.change_list).select { |entry| entry['field'] == key }
                            .flat_map { |entry| Array(entry['add']) + Array(entry['remove']) }
    end
    private_class_method :recorded_values

    def self.with_people(field, ids, name_mode)
      offered = field.options.map { |option| option[:value].to_s }
      missing = ids.map(&:to_s).uniq - offered
      return field if missing.empty?

      people = User.where(id: missing).map { |person| { value: person.id, label: person.display_name(mode: name_mode) } }
      field.dup.tap { |copy| copy.options = field.options + people }
    end
    private_class_method :with_people

    def self.with_options(field, names)
      offered = field.options.map { |option| option[:value].to_s }
      missing = names.map(&:to_s).uniq - offered
      return field if missing.empty?

      field.dup.tap { |copy| copy.options = field.options + missing.map { |name| { value: name, label: name } } }
    end
    private_class_method :with_options

    def initialize(project:, user:, locale: I18n.locale, name_mode: User::PreferenceStore::NAME_DISPLAY_DEFAULT,
                   ticket_ids: [])
      @project = project
      @user = user
      @locale = locale
      @name_mode = name_mode
      @ticket_ids = Array(ticket_ids)
    end

    # The offered fields, in group order; inside a group the definitions in
    # their own order, then the associations.
    def call
      fields = definition_fields + association_fields
      fields.each_with_index.sort_by { |field, index| [GROUPS.index(field.group), index] }.map(&:first)
    end

    private

    def definition_fields
      @project.ticket_attribute_definitions.active.ordered
              .reject { |definition| ASSOCIATION_KEYS.include?(definition.name) }
              .filter_map { |definition| from_definition(definition) }
    end

    def association_fields
      [
        Field.new(key: TAGS, label: I18n.t('views.organisations.tickets.bulk.fields.tags', locale: @locale),
                  group: 'ticket', kind: 'multi', options: tag_options, creatable: true),
        Field.new(key: ASSIGNEES, label: I18n.t('views.organisations.tickets.bulk.fields.assignees', locale: @locale),
                  group: 'people', kind: 'multi', options: people_options, removable: method(:removable_people)),
        Field.new(key: WATCHERS, label: I18n.t('views.organisations.tickets.bulk.fields.watchers', locale: @locale),
                  group: 'people', kind: 'multi', options: people_options, removable: method(:removable_people))
      ]
    end

    def from_definition(definition)
      kind = KIND_BY_FIELD_TYPE[definition.field_type]
      return nil unless kind

      Field.new(
        key: definition.name,
        label: definition.label_for(@locale),
        group: group_for(definition),
        kind: kind,
        options: options_for(definition),
        definition: definition
      )
    end

    # The project's own fields stand first: the ones the list sorts by and the
    # deadline, however the project named them.
    def group_for(definition)
      return 'ticket' if Ticket::SORTABLE_CUSTOM_ATTRIBUTES.include?(definition.name) || definition.deadline?

      'custom'
    end

    def options_for(definition)
      definition.allowed_values.map do |option|
        { value: option['value'], label: definition.display_value(option['value'], @locale) }
      end
    end

    # The organisation's tags the user may see: a tag is a name, the same on
    # every ticket, and a member does not learn the names of projects it
    # cannot open (TagPolicy::Scope, the rule of every other tag list).
    def tag_options
      tags = TagPolicy::Scope.new(@user, Tag.where(organisation_id: @project.organisation_id)).resolve
      tags.order(:name).pluck(:name).map do |name|
        { value: name, label: name }
      end
    end

    # Whoever may read the project's tickets and is an active member can be
    # assigned to one or watch one (Project#assignable_users, which
    # Ticket#assignable_user_ids reads too), named the way the reader sees names
    # everywhere.
    def people_options
      @people_options ||= people_to_options(@project.assignable_users)
    end

    # Who may be REMOVED (Field#removable): every member of the organisation,
    # deactivated ones included, and whoever is assigned to or has a
    # subscription on the tickets of the change. RemoveMembershipService deletes
    # a membership and leaves those rows; without the second half that person
    # could be taken off a ticket only in the edit form. The tickets are this
    # project's (a foreign id finds nothing), so never a person of another
    # organisation. Three small id lists, by index, instead of one OR over all
    # users.
    def removable_people
      @removable_people ||= begin
        tickets = @project.tickets.where(id: @ticket_ids).select(:id)
        ids = @project.organisation.memberships.pluck(:user_id) |
              TicketAssignment.where(ticket_id: tickets).distinct.pluck(:user_id) |
              NotificationSubscription.where(subscribable_type: 'Ticket', subscribable_id: tickets).distinct.pluck(:user_id)
        people_to_options(User.where(id: ids))
      end
    end

    def people_to_options(users)
      users.to_a.map { |user| { value: user.id, label: user.display_name(mode: @name_mode) } }
           .sort_by { |option| option[:label].downcase }
    end
  end
end
