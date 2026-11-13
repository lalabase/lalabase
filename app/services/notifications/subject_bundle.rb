# frozen_string_literal: true

# One ticket is one inbox row: an action on a row takes every in-app
# notification the person holds about the same subject along. This is the ONE
# place that says which rows those are and locks them, for the action on a
# single row (Actors::ChangeNotificationState) and for the bulk bar
# (Actors::ChangeNotificationStates).
#
# The rows are the ones the person may see (Notification.accessible_for) in
# the organisation that is NAMED, not read from the ambient tenant: the inbox
# above the organisations has none of its own. The caller runs under the
# tenant of that organisation.
#
# Entry point: lock
module Notifications
  class SubjectBundle
    class << self
      # Every notification of `user` in `organisation` they may see, all channels.
      def visible(user:, organisation:)
        user.notifications
            .where(organisation_id: organisation.id)
            .accessible_for(user, organisation)
      end

      # Locks `chosen` (rows within `visible`) and the in-app notifications about
      # their subjects, and answers the locked rows as a relation within `visible`.
      #
      # The whole set is locked before any member changes, by ONE statement in id
      # order, for every caller. Otherwise two actions on different members of a
      # bundle each hold their own row and wait for the other's. A notification
      # that arrives after the lock belongs to the next action.
      #
      # Runs inside the caller's transaction.
      def lock(visible:, chosen:)
        subjects = chosen.reorder(nil).distinct.pluck(:notifiable_type, :notifiable_id)
        whole = subjects.group_by(&:first).reduce(chosen) do |rows, (type, pairs)|
          rows.or(visible.channel_in_app.where(notifiable_type: type, notifiable_id: pairs.map(&:last)))
        end
        visible.where(id: whole.reorder(:id).lock.pluck(:id))
      end
    end
  end
end
