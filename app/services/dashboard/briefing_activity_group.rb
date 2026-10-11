# frozen_string_literal: true

module Dashboard
  # Aggregates several Activities into one briefing entry per (Trackable, Actor).
  # Reduces activity-stream noise ("Anna created, assigned, edited #142"
  # → one entry instead of three).
  #
  # Headline hierarchy (MVP): created > assigned > commented > status_changed > edited.
  # All Activities that are not the headline are counted towards secondary_count.
  class BriefingActivityGroup
    HEADLINE_RANK = {
      created: 1,
      assigned: 2,
      commented: 3,
      status_changed: 4,
      edited: 5
    }.freeze

    # Mapping from Activity#action to headline symbol.
    ACTION_TO_HEADLINE = {
      'created' => :created,
      'assigned' => :assigned,
      'unassigned' => :assigned,
      'post_added' => :commented,
      'status_changed' => :status_changed
      # everything else falls back to :edited
    }.freeze

    attr_reader :trackable, :actor, :headline_action, :secondary_count, :latest_at, :latest_activity

    def initialize(trackable:, actor:, headline_action:, secondary_count:, latest_at:, latest_activity:)
      @trackable = trackable
      @actor = actor
      @headline_action = headline_action
      @secondary_count = secondary_count
      @latest_at = latest_at
      @latest_activity = latest_activity
    end

    def self.headline_for(action)
      ACTION_TO_HEADLINE.fetch(action, :edited)
    end

    # Aggregates a flat Activity list into groups per (Trackable, Actor).
    # @param activities [Array<Activity>] freshly loaded, newest first
    # @return [Array<BriefingActivityGroup>] sorted by latest_at DESC
    def self.aggregate(activities)
      grouped = activities.group_by { |a| [a.trackable_type, a.trackable_id, a.actor_id] }

      grouped.values.map do |group_activities|
        headline_action, headline_activity = pick_headline(group_activities)
        BriefingActivityGroup.new(
          trackable: headline_activity.trackable,
          actor: headline_activity.actor,
          headline_action: headline_action,
          secondary_count: group_activities.size - 1,
          latest_at: group_activities.map(&:created_at).max,
          latest_activity: headline_activity
        )
      end.sort_by { |g| -g.latest_at.to_f }
    end

    def self.pick_headline(activities)
      ranked = activities.map { |a| [HEADLINE_RANK.fetch(headline_for(a.action), 99), a] }
      _, chosen = ranked.min_by { |rank, a| [rank, -a.created_at.to_f] }
      [headline_for(chosen.action), chosen]
    end
    private_class_method :pick_headline

    # Bootstrap icon for the headline action. Overrides the action mapping
    # of the individual Activity, because the headline now represents the group.
    def icon
      case headline_action
      when :created then 'plus-circle'
      when :assigned then 'person-plus'
      when :commented then 'chat-left-text'
      when :status_changed then 'arrow-right-circle'
      else 'pencil'
      end
    end

    def css_class
      case headline_action
      when :created then 'text-success'
      when :assigned then 'text-info'
      when :commented then 'text-cobalt-600'
      when :status_changed then 'text-purple-600'
      else 'text-muted'
      end
    end

    # Enough detail to render a relevant sub-action in the view
    # (e.g. status value for :status_changed). Currently only the backend mapping.
    delegate :trackable_display_name, to: :latest_activity
  end
end
