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
# on top of the lists, and a client that polls the token inbox with
# `arrived_since` gets it (its `since` cuts on happened_at). arrival
# is that rule. A fold asks it, and so does whoever writes a new row
# (GroupKeyBuilder#create_new_group). first_event_at stays the earliest
# event's own time, happened_at the latest one's: the time a row shows. An
# event without a time of its own (`at: nil`) has arrived now: the count rises,
# last_event_at is the time of the write, the other two stay.
#
# The row's line, its actor_id and the payload's single values (activity_id,
# action, parameters), names the event at happened_at: an earlier event that
# folds in late adds its actor and its lists (post_ids) and leaves the line to
# the later one, so a row never shows one event's actor beside another's time.
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
          # Asked before happened_at moves: the row's line (its actor, the
          # payload's single values) names the event at happened_at. An earlier
          # event folding in late leaves it to the later one.
          leads = leads?(notification, at)
          # The span only widens: events of one row can arrive out of order (a
          # retried outbox event). The lists order by last_event_at and print
          # happened_at, and Posts::MarkRead matches a comment row without post
          # ids (written before them, when last_event_at was the event's own
          # time) by first_event_at..last_event_at.
          notification.first_event_at = [notification.first_event_at, at].compact.min
          # Before last_event_at moves: a row without happened_at answers it.
          notification.happened_at = [notification.happened_at, at].compact.max
          notification.last_event_at = [notification.last_event_at, arrival(at: at)].compact.max
          merge_actors(notification, actor_id, leads: leads)
          merge_payload(notification, payload, leads: leads)
          notification.save!
          true
        end
      end

      private

      # Whether the event becomes the row's latest one, the event its line names:
      # not earlier than happened_at. An event without a time of its own leaves
      # happened_at, and the line, where they are.
      def leads?(notification, at)
        !at.nil? && at >= notification.happened_at
      end

      # actor_ids: every actor of the row once, the leading one (actor_id, the
      # actor of the event the line names) last, so a reader that walks the list
      # from the end meets the actors newest first. An actor of an earlier event
      # joins before the leading one.
      def merge_actors(notification, new_actor_id, leads: true)
        lead = leads && new_actor_id ? new_actor_id : notification.actor_id
        actors = Array(notification.payload['actor_ids']) + [notification.actor_id, new_actor_id]
        actors = actors.compact.uniq - [lead]
        notification.payload['actor_ids'] = lead ? actors + [lead] : actors
        notification.actor_id = lead
      end

      # Lists are joined, whoever leads. A single value (activity_id, action,
      # parameters) is the leading event's: an earlier event only gives one the
      # row lacks.
      def merge_payload(notification, new_payload, leads: true)
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
                                      elsif leads || !notification.payload.key?(key)
                                        value
                                      else
                                        existing
                                      end
        end
      end
    end
  end
end
