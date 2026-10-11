# frozen_string_literal: true

module Notifications
  # Recomputes and broadcasts the org switcher signal off the request path
  # (Notifications::UnreadSignals). Runs without an ambient tenant: the
  # service scopes each query to its organisation itself.
  class UnreadSignalsJob < ApplicationJob
    queue_as :default

    # One run per user at a time, in enqueue order: an older run that computed
    # before a "mark read" must not broadcast its stale dot after the newer run.
    # Blocked runs wait; the last one to run always counts the current state.
    limits_concurrency to: 1, key: ->(*args, **kwargs) { kwargs[:user_id] || args.first&.[](:user_id) },
                       duration: 5.minutes, on_conflict: :block

    def perform(user_id:)
      user = User.find_by(id: user_id)
      return unless user

      Notifications::UnreadSignals.call(user: user)
    end
  end
end
