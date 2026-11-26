# frozen_string_literal: true

# Folds one more event into a notification row that already exists. This is
# the one place that changes group_count, first_event_at, last_event_at and
# happened_at of such a row, together with the actor and the payload the event
# brings. A new writer of those columns calls it instead of setting them itself.
#
# fold! takes the row's lock, which reads the row again, and decides on what
# the database holds then: a row that was read or archived after the caller
# loaded it takes no event. The caller's own rule comes as a block and is asked
# about the re-read row. The row is saved with save!, so validations and
# callbacks run (the unread signal among them).
#
# last_event_at says when the latest event reached the row: the time of the
# write, never before the event's own time, never before the row's own value.
# So a row that is written late, or that takes an earlier event late, stands
# on top of the lists, and a client that polls with `since` gets it. arrival
# is that rule. A fold asks it, and so does whoever writes a new row
# (GroupKeyBuilder#create_new_group). first_event_at stays the earliest
# event's own time, happened_at the latest one's: the time a row shows. An
# event without a time of its own (`at: nil`) has arrived now: the count rises,
# last_event_at is the time of the write, the other two stay.
#
# Entry point: fold!, arrival
module Notifications
  module RowEvents
    class << self
      # The moment an event of the time `at` reaches a row that is written now: the
      # time of the write, never before the event's own time. nil: the event has no
      # time of its own.
      def arrival(at:)
        [at, Time.current].compact.max
      end

      # true: the event is folded in and saved. false: nothing was written.
      #
      # The block, if given, gets the row as read under the lock; a falsy answer
      # refuses the fold. The row object must carry no unsaved changes: the lock
      # reloads it and raises otherwise.
      def fold!(notification:, at:, actor_id: nil, payload: nil)
        notification.with_lock do
          # Deliberate duplication of a check in GroupKeyBuilder#can_add_to_group?:
          # here it holds for every caller. The caller's block brings the rest; for
          # the builder that includes an email that left the queue. If fold! gets a
          # second caller, decide then whether those checks move here.
          next false if notification.state_read? || notification.state_archived?
          next false if block_given? && !yield(notification)

          notification.group_count += 1
          # The span only widens: events of one row can arrive out of order (a
          # retried outbox event). The lists order by last_event_at and print
          # happened_at, and Posts::MarkRead matches a comment row without post
          # ids (written before them, when last_event_at was the event's own
          # time) by first_event_at..last_event_at.
          notification.first_event_at = [notification.first_event_at, at].compact.min
          # Before last_event_at moves: a row without happened_at answers it.
          notification.happened_at = [notification.happened_at, at].compact.max
          notification.last_event_at = [notification.last_event_at, arrival(at: at)].compact.max
          merge_actors(notification, actor_id)
          merge_payload(notification, payload)
          notification.save!
          true
        end
      end

      private

      def merge_actors(notification, new_actor_id)
        actors = (notification.payload['actor_ids'] || []).dup
        actors << notification.actor_id if notification.actor_id
        actors << new_actor_id if new_actor_id
        notification.payload['actor_ids'] = actors.uniq.compact
        notification.actor_id = new_actor_id if new_actor_id
      end

      def merge_payload(notification, new_payload)
        return unless new_payload

        notification.payload ||= {}

        new_payload.each do |key, value|
          key = key.to_s
          existing = notification.payload[key]

          notification.payload[key] = if existing.is_a?(Array) && value.is_a?(Array)
                                        (existing + value).uniq
                                      elsif existing.is_a?(Array)
                                        (existing + [value]).uniq
                                      elsif value.is_a?(Array)
                                        ([existing] + value).compact.uniq
                                      else
                                        value
                                      end
        end
      end
    end
  end
end
