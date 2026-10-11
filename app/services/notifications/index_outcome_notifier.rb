# frozen_string_literal: true

module Notifications
  # Notifies the user who connected a repository when its code index finishes
  # (index_completed) or fails (index_failed). Driven by ProjectIndexerJob (the
  # initial index) and the shared JobSupport#fail_index! (any failure). Push
  # re-index SUCCESS deliberately stays silent — only the initial index notifies
  # on success by default (see RepoReindexJob).
  #
  # Why a direct Notification.create! instead of the Activity/FanoutService
  # pipeline: an index outcome is a SYSTEM event (no human actor, no Activity
  # row) with exactly ONE known recipient (connected_by_user). FanoutService
  # exists to answer "who should get this?" — here we already know, so we build
  # the per-channel rows directly and skip the Suppressor/Subscription machinery
  # that path entails.
  #
  # Configurable: both channels honour the user's NotificationPreference for the
  # event type (default = on), so the user can mute or pick channels in the
  # preferences UI.
  #
  # Best-effort: a notification failure must NEVER break (or fail) the indexing
  # job that triggered it, so every channel delivery is independently guarded.
  class IndexOutcomeNotifier
    EVENT_TYPES = {
      completed: Constants::EVENT_TYPE_INDEX_COMPLETED,
      failed: Constants::EVENT_TYPE_INDEX_FAILED
    }.freeze

    CHANNELS = [Constants::CHANNEL_IN_APP, Constants::CHANNEL_EMAIL].freeze

    # Notification-center ranking scores (0–100). A failure outranks a routine
    # "ready" so it sorts above successes in the center.
    SCORE_FAILED = 70
    SCORE_COMPLETED = 40

    def self.call(repository:, outcome:)
      new(repository: repository, outcome: outcome).call
    end

    def initialize(repository:, outcome:)
      @repository = repository
      @outcome = outcome.to_sym
      @event_type = EVENT_TYPES.fetch(@outcome)
    end

    def call
      recipient = @repository.connected_by_user
      return if recipient.nil? || !recipient.active?

      CHANNELS.each { |channel| deliver_to(recipient, channel) }
    rescue StandardError => e
      # Best-effort contract: even the recipient resolution above (connected_by_user
      # / active?) must never raise into the indexing job that called us. The
      # per-channel rescue handles channel failures; this guards the rest.
      Rails.logger.error("IndexOutcomeNotifier(#{@event_type}) failed for repo #{@repository.id}: #{e.message}")
      nil
    end

    private

    # Independent + guarded per channel: one channel being disabled or failing
    # must not stop the other, and nothing may propagate into the indexing job.
    def deliver_to(recipient, channel)
      return unless channel_enabled?(recipient, channel)

      notification = build_notification(recipient, channel)
      if channel == Constants::CHANNEL_EMAIL
        EmailDeliveryJob.perform_later(notification.id)
      else
        Notifications::BroadcastService.new(notification).broadcast_creation
      end
    rescue ActiveRecord::RecordNotUnique
      nil # idempotent: this exact outcome was already notified on this channel
    rescue StandardError => e
      Rails.logger.error(
        "IndexOutcomeNotifier(#{@event_type}/#{channel}) failed for repo #{@repository.id}: #{e.message}"
      )
      nil
    end

    def channel_enabled?(recipient, channel)
      NotificationPreference.resolve_for(
        user: recipient, event_type: @event_type, channel: channel, scope: @repository
      ).should_deliver_now?
    end

    def build_notification(recipient, channel)
      Notification.create!(
        organisation: @repository.organisation,
        recipient: recipient,
        notifiable: @repository,
        project: @repository.project,
        event_type: @event_type,
        channel: channel,
        priority: @outcome == :failed ? Constants::PRIORITY_HIGH : Constants::PRIORITY_NORMAL,
        score: @outcome == :failed ? SCORE_FAILED : SCORE_COMPLETED,
        payload: { 'repository_id' => @repository.id, 'full_name' => @repository.full_name,
                   'outcome' => @outcome.to_s },
        # Separate group per outcome so a failure never folds into a prior success.
        group_key: "project_repository:#{@repository.id}:#{@event_type}",
        dedupe_fingerprint: dedupe_fingerprint(channel)
      )
    end

    # Distinct per outcome event (a later index of a NEW commit re-notifies), but
    # a duplicate call for the SAME outcome collides on the unique index and is
    # rescued above.
    def dedupe_fingerprint(channel)
      Digest::SHA256.hexdigest("#{@event_type}:#{@repository.id}:#{channel}:#{discriminator}")
    end

    def discriminator
      @discriminator ||= begin
        index = @repository.project_index
        # A failure never sets last_indexed_at, so updated_at (bumped by the
        # status→failed write right before this runs) is the only per-failure-
        # distinct stamp; a success has a fresh last_indexed_at.
        stamp = @outcome == :completed ? index&.last_indexed_at : index&.updated_at
        (stamp || Time.current).to_i
      end
    end
  end
end
