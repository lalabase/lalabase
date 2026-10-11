# frozen_string_literal: true

# Collapses short change cascades into one timeline item while preserving the
# ordering contract of the page that supplied them.
# Entry point: for_project
module Activities
  # The ticket timeline uses its strict adjacent mode; the project page uses an
  # object-scoped mode where another object's event does not split the run.
  class RunCollapser
    WINDOW = 30.minutes
    FIELD_FOR_ACTION = {
      'subscriber_added' => :subscribers,
      'subscriber_removed' => :subscribers,
      'assigned' => :assignees,
      'unassigned' => :assignees,
      'status_changed' => :status,
      'priority_changed' => :priority,
      'title_changed' => :title,
      'description_changed' => :description
    }.freeze

    ActivityRun = Struct.new(:activities) do
      delegate :created_at, :actor, :actor_id, :trackable, to: :newest
      delegate :size, to: :activities

      def oldest = activities.min_by(&:created_at)
      def newest = activities.max_by(&:created_at)
      def first_at = oldest.created_at
      def fields = activities.filter_map { |activity| FIELD_FOR_ACTION[activity.action] }.uniq
      def field = fields.one? ? fields.first : :multiple
    end

    class << self
      def for_ticket(items)
        ordered = Array(items)
        collapse(ordered, chronological: ordered, object_scoped: false, cross_field: false)
      end

      def for_project(items)
        ordered = Array(items)
        chronological = ordered.sort_by { |item| timestamp_for(item) }
        collapse(ordered, chronological:, object_scoped: true, cross_field: true)
      end

      private

      def collapse(ordered, chronological:, object_scoped:, cross_field:)
        runs = object_scoped ? object_runs(chronological, cross_field:) : adjacent_runs(chronological, cross_field:)

        rebuild(ordered, runs)
      end

      def adjacent_runs(items, cross_field:)
        runs = []
        current = []

        items.each do |item|
          unless aggregatable?(item)
            runs << current if current.any?
            current = []
            next
          end

          if current.any? && !continues?(current.last, item, cross_field:)
            runs << current
            current = []
          end
          current << item
        end

        runs << current if current.any?
        runs
      end

      def object_runs(items, cross_field:)
        active = {}
        finished = []

        items.each do |item|
          key = target_key(item)
          next unless key

          unless aggregatable?(item)
            finished << active.delete(key) if active[key]
            next
          end

          current = active[key]
          if current && (!continues?(current.last, item, cross_field:) || !same_day?(current.last, item))
            finished << current
            current = nil
          end
          active[key] = Array(current) << item
        end

        finished.concat(active.values)
      end

      def rebuild(ordered, runs)
        replacements = {}.compare_by_identity
        runs.each do |activities|
          next if activities.size < 2

          run = ActivityRun.new(activities)
          activities.each { |activity| replacements[activity] = run }
        end

        ordered.filter_map do |item|
          run = replacements[item]
          next item unless run
          next unless item.equal?(run.newest)

          run
        end
      end

      def aggregatable?(item)
        item.is_a?(Activity) && FIELD_FOR_ACTION.key?(item.action)
      end

      def continues?(previous, item, cross_field:)
        same_field = cross_field || FIELD_FOR_ACTION[previous.action] == FIELD_FOR_ACTION[item.action]
        same_field && previous.actor_id == item.actor_id && item.created_at - previous.created_at <= WINDOW
      end

      def target_key(item)
        return unless item.is_a?(Activity)

        target = target_for(item)
        type = target&.class&.base_class&.name || item.trackable_type
        id = target&.id || item.trackable_id
        [type, id]
      end

      def target_for(activity)
        Activities::ProjectTarget.call(activity)
      end

      def same_day?(previous, item)
        previous.created_at.to_date == item.created_at.to_date
      end

      def timestamp_for(item)
        item.respond_to?(:created_at) && item.created_at ? item.created_at : Time.current
      end
    end
  end
end
