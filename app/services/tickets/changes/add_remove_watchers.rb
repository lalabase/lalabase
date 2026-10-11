# frozen_string_literal: true

# The ticket's watchers (follow subscriptions). Added ones are manual
# subscriptions made by the actor, as "subscribe_other" does; removed are only
# the ones a person can revoke in the ticket head as well: the manual ones.
# A subscription that came with an assignment or with creating the ticket has
# its own lifecycle and is left alone.
#
# Entry point: apply
module Tickets
  module Changes
    class AddRemoveWatchers < AddRemoveBase
      private

      def current(ticket)
        NotificationSubscription.where(subscribable: ticket, mode: :follow).pluck(:user_id).map(&:to_s)
      end

      # A watcher the run took off who may not follow any more stays off (the
      # subscription would be refused, NotificationSubscription
      # #validate_user_has_access); whoever follows still stays.
      def restorable(ticket, values)
        following = current(ticket)
        allowed = ticket.project.assignable_users.where(id: values - following).pluck(:id).map(&:to_s)
        values.select { |value| following.include?(value) || allowed.include?(value) }
      end

      def write(ticket, values, before)
        added = values - before
        removed = before - values
        added.each do |user_id|
          user = User.find(user_id)
          NotificationSubscription.subscribe_other(user: user, item: ticket, subscribed_by: Current.user)
          ticket.track_subscriber_added(user)
        end
        NotificationSubscription.where(subscribable: ticket, user_id: removed, mode: :follow,
                                       source: NotificationSubscription::SOURCE_MANUAL).find_each do |subscription|
          user = subscription.user
          subscription.destroy!
          ticket.track_subscriber_removed(user)
        end
        ticket.touch if added.any? || removed.any?
      end
    end
  end
end
