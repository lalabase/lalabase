# frozen_string_literal: true

# Removes a comment's text excerpt from its post_added activities and from every
# notification that copied their parameters (Notifications::FanoutService#build_payload
# stores activity_id next to them). For a comment that is private now: the feed, the
# activities API and a notification card show the excerpt to everyone, the comment
# itself only to Post.readable_by. Returns the number of activities it cleaned.
module Posts
  class ExcerptRedaction
    def self.call(post:)
      new(post:).call
    end

    def initialize(post:)
      @post = post
    end

    def call
      activities = Activity.where(action: 'post_added', secondary: @post)
                           .where("activities.parameters->>'post_excerpt' IS NOT NULL")
      activity_ids = activities.pluck(:id)
      return 0 if activity_ids.empty?

      # Both or neither: the rake task finds its posts through the activity's excerpt,
      # so an activity cleaned without its notifications would never be picked up again.
      ActiveRecord::Base.transaction do
        activities.update_all("parameters = parameters - 'post_excerpt'")
        Notification.where("notifications.payload->>'activity_id' IN (?)", activity_ids)
                    .update_all("payload = (payload - 'post_excerpt') #- '{parameters,post_excerpt}'")
      end
      activity_ids.size
    end
  end
end
