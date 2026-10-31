# frozen_string_literal: true

# Side-effect chain map: docs/architektur/seiteneffekt_ketten.md
#
# The NotificationFanoutService determines WHO should receive a notification.
#
# PURPOSE:
# When something happens (ticket comment, assignment, etc.), we need to decide
# which users should receive a notification.
#
# DUAL-PATH:
# - Tickets: Simple subscription-based system. Whoever is subscribed receives
#   notifications (filtered by user settings for event types).
# - Non-tickets (Project, Document, etc.): Existing score-based logic with
#   ScoreCalculator + Suppressor.
#
# EXAMPLE:
# Ticket #123 gets a comment from Tim
# → Service finds all subscribers: Sarah (assignee), Max (watcher), Lisa (creator)
# → Checks user settings: Lisa has comment notifications off → skip
# → Creates 2 notifications (Sarah, Max) — but not for Tim (actor)

module Notifications
  class FanoutService
    include Notifications::Constants

    def initialize(outbox_event)
      @outbox_event = outbox_event
      @activity = outbox_event.activity
      @organisation = outbox_event.organisation
      @actor = @activity.actor
    end

    def call
      if @activity.action == 'post_added' && @activity.secondary_type == 'Post'
        ActsAsTenant.with_tenant(@organisation) do
          PostRead.synchronize(post_id: @activity.secondary_id) { perform_fanout }
        end
      else
        perform_fanout
      end
    rescue StandardError => e
      Rails.logger.error "NotificationFanoutService failed: #{e.message}"
      { success: false, error: e.message }
    end

    private

    def perform_fanout
      return { success: true, recipients: 0 } unless should_create_notifications?

      recipients = find_recipients
      return { success: true, recipients: 0 } if recipients.empty?

      notifications_created = 0
      is_ticket = @activity.trackable.is_a?(Ticket)

      # Score calculation only needed for non-ticket notifications
      recipient_scores = is_ticket ? {} : batch_calculate_scores(recipients)

      # Pre-fetch all data needed in the loop to avoid N+1 queries
      prefetch_data = prefetch_loop_data(recipients)

      created_in_app_notifications = []
      email_notifications = []

      ActsAsTenant.with_tenant(@organisation) do
        recipients.each do |recipient|
          channels = determine_channels_for_recipient(recipient, prefetch_data)

          channels.each do |channel|
            score = recipient_scores[recipient.id] || 50 # Default score for tickets

            if is_ticket
              next unless should_notify_for_ticket?(recipient)
            else
              next unless should_notify_for_generic?(recipient, channel, score, prefetch_data)
            end

            notification = create_or_update_notification(recipient, channel, score, prefetch_data)
            notifications_created += 1 if notification

            created_in_app_notifications << notification if notification&.channel_in_app? && notification.unread?
            email_notifications << notification if notification&.should_send_immediately?
          end
        end

        # Batch operations after the loop
        batch_broadcast(created_in_app_notifications) if created_in_app_notifications.any?
        batch_schedule_delivery(email_notifications) if email_notifications.any?
      end

      {
        success: true,
        recipients: recipients.size,
        notifications_created: notifications_created
      }
    end

    def should_create_notifications?
      return false if @actor&.is_ai?
      return false if @activity.parameters&.dig('skip_notifications')

      # Skip notifications for archived projects
      trackable = @activity.trackable
      return false if trackable&.try(:project)&.archived?
      return false if trackable.is_a?(Project) && trackable.archived?

      skip_actions = %w[viewed exported downloaded logged_time]
      return false if skip_actions.include?(@activity.action)

      # Skip ticket creation notifications when ticket has assignees
      # (assignees get separate assignment notifications)
      if @activity.key == 'ticket.created' && @activity.trackable_type == 'Ticket'
        ticket = @activity.trackable
        return false if ticket&.assignees&.any?
      end

      true
    end

    # =========================================================================
    # Recipient Finding
    # =========================================================================

    def find_recipients
      notifiable = @activity.trackable

      if bulk_run_activity?
        find_bulk_run_recipients(notifiable)
      elsif notifiable.is_a?(Ticket)
        find_ticket_recipients(notifiable)
      else
        find_generic_recipients(notifiable)
      end
    end

    # A bulk change of several tickets is ONE event on the project
    # (doc/ticket_bulk_edit_plan.md, D4): its recipients are the followers of
    # the tickets the run changed, as for a status change on each of them,
    # minus the actor, each checked for access to the project's tickets.
    def bulk_run_activity?
      @activity.trackable.is_a?(Project) &&
        %w[tickets_bulk_changed tickets_bulk_undone tickets_bulk_moved tickets_bulk_deleted].include?(@activity.action)
    end

    # A delete took the subscriptions with the tickets: its run activity
    # carries the followers it read before (follower_ids, slice 7).
    def find_bulk_run_recipients(project)
      followers = bulk_run_followers
      recipients = followers.to_set
      recipients.delete(@actor) if @actor
      with_current_access(recipients.to_a, project, :tickets)
    end

    def bulk_run_followers
      parameters = @activity.parameters || {}
      return User.where(id: Array(parameters['follower_ids'])).select(&:active?) if parameters.key?('follower_ids')

      ticket_ids = Array(parameters['ticket_ids'])
      return [] if ticket_ids.empty?

      NotificationSubscription.includes(:user)
                              .where(subscribable_type: 'Ticket', subscribable_id: ticket_ids, mode: :follow)
                              .filter_map(&:user)
                              .select(&:active?)
                              .uniq
    end

    # Simple subscription-based recipient finding for tickets.
    # Recipients = subscribers + mentioned users + assignment targets.
    def find_ticket_recipients(ticket)
      recipients = Set.new

      # 1. All active subscribers (follow mode only)
      subscribers = NotificationSubscription.includes(:user)
                                            .where(subscribable: ticket, mode: :follow)
                                            .select { |sub| sub.user&.active? }
                                            .map(&:user)
      recipients.merge(subscribers)

      # 2. Mentioned users (always, regardless of subscription)
      add_mentioned_users(recipients) if derive_event_type == EVENT_TYPE_MENTION

      # 3. Assignment target (always gets the assignment notification)
      # GDPR: Use activity.secondary (User reference) instead of PII in parameters
      recipients.add(@activity.secondary) if derive_event_type == EVENT_TYPE_TICKET_ASSIGNED && @activity.secondary.is_a?(User) && @activity.secondary.active?

      # 4. Unassignment target (always gets the unassignment notification)
      # GDPR: Use activity.secondary (User reference) instead of PII in parameters
      recipients.add(@activity.secondary) if derive_event_type == EVENT_TYPE_TICKET_UNASSIGNED && @activity.secondary.is_a?(User) && @activity.secondary.active?

      # Remove actor (don't notify yourself)
      recipients.delete(@actor) if @actor
      readers_of_the_comment(with_current_access(recipients.select(&:active?), ticket.project, :tickets))
    end

    # A comment's notification carries its text (the mail body, the card excerpt), and
    # a mention points at it: only who may read the comment gets one (Post.readable_by).
    def readers_of_the_comment(users)
      post = @activity.secondary
      return users unless post.is_a?(Post)

      users.select { |user| post.readable_by?(user) }
    end

    # Existing complex recipient finding for non-ticket items (Project, Document, Note).
    def find_generic_recipients(notifiable)
      recipients = Set.new

      subscribers_with_users = find_subscribers_with_users(notifiable)
      active_subscriber_users = subscribers_with_users.select { |sub| sub.active? && sub.user&.active? }
                                                      .map(&:user)

      case notifiable
      when Project
        project_members = find_project_members_with_access_optimized(notifiable, gated_area_for(notifiable))
        recipients.merge(project_members)
        recipients.merge(active_subscriber_users)

      when Document, Note
        if notifiable.respond_to?(:project) && notifiable.project
          project_members = find_project_members_with_access_optimized(notifiable.project,
                                                                       Notification.area_for(notifiable))
          recipients.merge(project_members)
        end
        recipients.add(notifiable.creator) if notifiable.respond_to?(:creator) && notifiable.creator
        recipients.merge(active_subscriber_users)
      end

      recipients.delete(@actor) if @actor
      with_current_access(recipients.select(&:active?), gated_project_for(notifiable), gated_area_for(notifiable))
    end

    # A subscription is not a standing permission.
    #
    # The row keeps pointing at its project long after the person was taken off that
    # project, and nothing in the row itself knows it. So every recipient set passes the
    # CURRENT access check before a notification is written for it. This covers the
    # subscribers the two branches above merge in WITHOUT re-checking rights, and it
    # covers the ticket path's mention and assignment targets too.
    #
    # Derived, never stored. That is the whole point: putting someone back on the project
    # makes their old subscriptions and notifications work again with no repair step, and
    # a mute they set themselves survives the round trip. Deleting the rows on removal
    # would lose both.
    #
    # Losing the ORGANISATION rides along for free: ProjectAccessService#can? asks
    # active_member? before it looks at any project, and before the admin shortcut.
    #
    # A notification without a project (system messages) has no project to check against
    # and passes through.
    def with_current_access(users, project, area)
      return [] if area == Notification::UNMAPPED_EVENT
      return users if project.nil?

      users.select do |user|
        if area
          AccessCheck::ProjectAccessService.new(user, project).can?(:read, area)
        else
          # Project-level news: "may see the project at all", the question the
          # project_members branch above already asks. There is no single area to name.
          AccessCheck::ProjectAccessService.can_access_project?(user, project)
        end
      end
    end

    # The project a notifiable's access is measured against, or nil when it has none.
    def gated_project_for(notifiable)
      return notifiable if notifiable.is_a?(Project)
      return notifiable.project if notifiable.respond_to?(:project)

      nil
    end

    # The area of the notifiable, from the one mapping every inbox surface reads
    # (Notification.area_for), so delivery and the inbox ask the same question. For
    # the project itself it is the area of the EVENT: a ticket moved in reaches who
    # may read tickets, not every member. nil = whole project.
    def gated_area_for(notifiable)
      Notification.area_for(notifiable, action: @activity.action)
    end

    def add_mentioned_users(recipients)
      mention_fields = %w[mentioned_users mentions mentioned_user_ids]
      return unless @activity.parameters

      mention_fields.each do |field|
        ids = @activity.parameters[field]
        next unless ids.is_a?(Array)

        mentioned = User.active.where(id: ids)
        recipients.merge(mentioned)
      end
    end

    # =========================================================================
    # Notification Filtering
    # =========================================================================

    # Simple ticket notification filter: self-action + user event-type settings.
    def should_notify_for_ticket?(recipient)
      return false if @actor == recipient
      return false unless recipient.ticket_notification_enabled_for?(derive_event_type)

      true
    end

    # Existing score-based filter for non-ticket notifications.
    def should_notify_for_generic?(recipient, channel, score, prefetch_data = {})
      guaranteed = guaranteed_recipient_ids.include?(recipient.id)

      # Use pre-fetched data for Suppressor if available
      prefetched_preference = resolve_preference_from_batch(
        prefetch_data, recipient.id, channel.to_s
      )
      prefetched_subscription = prefetch_data.dig(:subscriptions, recipient.id)

      suppressor = Suppressor.new(
        @activity, recipient, score, channel,
        guaranteed: guaranteed,
        prefetched_preference: prefetched_preference,
        prefetched_subscription: prefetched_subscription
      )

      return false if suppressor.should_suppress?

      true
    end

    # =========================================================================
    # Channel Determination
    # =========================================================================

    def determine_channels_for_recipient(recipient, prefetch_data = {})
      if @activity.trackable.is_a?(Ticket)
        # In-app-only escape hatch (mirrors the skip_notifications parameter in
        # should_create_notifications?): system-generated activities such as the
        # onboarding seed assignments must reach the inbox but never send mail.
        # Cutting the channel HERE (before notification creation) guarantees no
        # email Notification row exists that a later retry/job could deliver.
        return [:in_app] if @activity.parameters&.dig('skip_email')

        # DELIBERATE simplification: ticket channels are NOT controlled via the
        # hierarchical NotificationPreference system. Instead, tickets use the
        # simple JSONB toggles in User::NotificationSettings
        # (ticket_notify_on_comment?, etc.), which are checked in
        # should_notify_for_ticket? via the User facade
        # ticket_notification_enabled_for?.
        # This reduces complexity for the user — one toggle per event type
        # instead of nested channel preferences.
        %i[in_app email]
      else
        # Use pre-fetched preferences for non-tickets
        channels = [:in_app]
        email_preference = resolve_preference_from_batch(
          prefetch_data, recipient.id, 'email'
        )

        if email_preference
          channels << :email if email_preference.enabled?
        else
          # Fallback to DB query if no prefetch data available
          email_preference = NotificationPreference.resolve_for(
            user: recipient,
            event_type: derive_event_type,
            channel: :email,
            scope: @activity.trackable
          )
          channels << :email if email_preference.enabled?
        end
        channels
      end
    end

    # =========================================================================
    # Guaranteed Recipients (for non-ticket path)
    # =========================================================================

    def guaranteed_recipient_ids
      @guaranteed_recipient_ids ||= begin
        ids = Set.new
        notifiable = @activity.trackable

        case notifiable
        when Document, Note
          ids.add(notifiable.creator_id) if notifiable.respond_to?(:creator_id) && notifiable.creator_id
        end

        ids.delete(@actor&.id)
        ids
      end
    end

    # =========================================================================
    # Score Calculation (non-ticket path only)
    # =========================================================================

    def batch_calculate_scores(recipients)
      scores = {}

      recipients.each do |recipient|
        score = ScoreCalculator.new(@activity, recipient, @organisation).calculate
        scores[recipient.id] = score
      rescue StandardError => e
        Rails.logger.warn "Failed to calculate score for recipient #{recipient.id}: #{e.message}"
        scores[recipient.id] = 0
      end

      scores
    end

    # =========================================================================
    # Pre-Fetch & Batch Operations
    # =========================================================================

    # Pre-loads all data needed in the recipient loop to avoid N+1 queries.
    def prefetch_loop_data(recipients)
      data = {}
      recipient_ids = recipients.map(&:id)
      trackable = @activity.trackable
      is_ticket = trackable.is_a?(Ticket)

      # 1. Pre-fetch existing group notifications for GroupKeyBuilder.
      #    The group_key is the same for all recipients (based on activity data).
      sample_builder = GroupKeyBuilder.new(@activity, recipients.first)
      potential_group_key = sample_builder.build

      existing_groups_raw = Notification
                            .where(recipient_id: recipient_ids, group_key: potential_group_key)
                            .where('created_at > ?', GroupKeyBuilder::GROUP_TIME_WINDOW.ago)
                            .where('group_count < ?', GroupKeyBuilder::MAX_GROUP_SIZE)
                            .order(created_at: :desc)
                            .to_a

      data[:existing_groups] = {}
      existing_groups_raw.each do |notif|
        key = [notif.recipient_id, notif.group_key, notif.channel]
        data[:existing_groups][key] ||= notif # Keep first (most recent)
      end

      # 2. For non-ticket path: pre-fetch subscriptions and preferences
      unless is_ticket
        # Subscriptions for Suppressor
        data[:subscriptions] = NotificationSubscription
                               .where(user_id: recipient_ids, subscribable: trackable)
                               .index_by(&:user_id)

        # Preferences for channel determination + Suppressor
        # Load ALL preferences for these users + event_type to enable hierarchy resolution
        data[:preferences] = NotificationPreference
                             .where(user_id: recipient_ids, event_type: derive_event_type)
                             .to_a
                             .group_by(&:user_id)
      end

      data
    end

    # Batch broadcast for all created in_app notifications.
    # Computes unread counts per recipient in ONE query instead of per-notification.
    def batch_broadcast(notifications)
      return if notifications.empty?

      recipient_ids = notifications.map(&:recipient_id).uniq
      recipients_by_id = User.where(id: recipient_ids).index_by(&:id)

      # Use the user method path per recipient so that the broadcast count
      # applies the same accessible_for filtering as the HTTP render path.
      # Notifications from one fanout belong to the same organisation.
      organisation = notifications.first.organisation
      unread_counts = recipients_by_id.transform_values do |user|
        user.unread_notifications_count(organisation)
      end

      notifications.each do |notification|
        Notifications::BroadcastService.new(
          notification,
          precomputed_unread_count: unread_counts[notification.recipient_id] || 0
        ).broadcast_creation
      end
    end

    # Batch schedule delivery for all email notifications.
    def batch_schedule_delivery(notifications)
      notifications.each do |notification|
        schedule_delivery(notification)
      end
    end

    # In-memory hierarchical resolution from pre-loaded preferences:
    # 1. Item-level → 2. Project-level → 3. Org-level → 4. Global → 5. Default
    def resolve_preference_from_batch(prefetch_data, user_id, channel)
      user_prefs = prefetch_data.dig(:preferences, user_id)
      return nil unless user_prefs

      trackable = @activity.trackable
      channel_str = channel.to_s

      # Filter to matching channel
      matching = user_prefs.select { |p| p.channel == channel_str }

      # 1. Item-level
      if trackable
        found = matching.find { |p| p.scope_type == trackable.class.name && p.scope_id == trackable.id }
        return found if found

        # 2. Project-level
        if trackable.respond_to?(:project) && trackable.project
          found = matching.find { |p| p.scope_type == 'Project' && p.scope_id == trackable.project_id }
          return found if found
        end
      end

      # 3. Org-level
      found = matching.find { |p| p.scope_type.nil? && p.scope_id.nil? && p.organisation_id == @organisation.id }
      return found if found

      # 4. Global
      found = matching.find { |p| p.scope_type.nil? && p.scope_id.nil? && p.organisation_id.nil? }
      return found if found

      # 5. Default
      NotificationPreference.create_default_for(
        user: User.new(id: user_id),
        event_type: derive_event_type,
        channel: channel_str
      )
    end

    # =========================================================================
    # Helpers
    # =========================================================================

    def find_subscribers_with_users(notifiable)
      NotificationSubscription.includes(:user)
                              .where(subscribable: notifiable)
                              .where(users: { active: true })
    end

    # Everybody who may read `area` of the project, account admins included. nil is
    # project news, any area will do (Notification.area_for). An event without a rule
    # has no area to look up and reaches nobody (see #with_current_access).
    #
    # Deliberately no rescue. Until 2026-10-31 one answered with an empty list here,
    # so a lookup that raised on every project event passed as a success. Nothing is
    # written yet at this point: a failure leaves the event to its retry
    # (OutboxEvent#mark_failed).
    def find_project_members_with_access_optimized(project, area)
      return [] if project.nil? || area == Notification::UNMAPPED_EVENT

      readers = area ? project.users_with_access(:read, area) : project.users_with_any_access
      User.active.includes(:memberships, :roles).where(id: readers.select(:id)).to_a
    end

    def derive_event_type
      @derived_event_type ||= Notifications::Constants.derive_event_type(@activity.key, @activity.action)
    end

    def create_or_update_notification(recipient, channel, score = nil, prefetch_data = {})
      score ||= ScoreCalculator.new(@activity, recipient, @organisation).calculate

      notification_params = {
        organisation: @organisation,
        recipient: recipient,
        actor: @actor,
        notifiable: @activity.trackable,
        event_type: derive_event_type,
        channel: channel,
        priority: score >= 80 ? :high : :normal,
        state: :queued,
        score: score,
        payload: build_payload
      }

      group_builder = GroupKeyBuilder.new(
        @activity, recipient,
        existing_groups: prefetch_data[:existing_groups]
      )
      notification = group_builder.find_or_create_group(notification_params)
      reconcile_existing_post_reads(notification, recipient)
      notification
    end

    def schedule_delivery(notification)
      case notification.channel
      when 'email'
        EmailDeliveryJob.perform_later(notification.id)
      end
    end

    # A reaction may be recorded before the outbox job creates its in-app
    # notification. Reconcile the durable receipt while holding the same row
    # lock used by grouping, so acknowledged posts cannot reappear as unread.
    # Email lifecycle rows stay independent and continue through delivery.
    def reconcile_existing_post_reads(notification, recipient)
      return unless notification.channel_in_app?
      return unless notification.event_type_ticket_commented?

      notification.with_lock do
        post_ids = Array(notification.payload['post_ids']).map(&:to_s).uniq
        next if post_ids.empty?

        fully_read = PostRead.all_existing_posts_read?(
          organisation: @organisation,
          user: recipient,
          post_ids: post_ids
        )
        notification.mark_as_read! if fully_read
      end
    end

    def build_payload
      # GDPR: No PII (names, emails) in payload. Consumers resolve names
      # via activity.secondary and activity.actor at display time.
      payload = {
        activity_id: @activity.id,
        action: @activity.action,
        parameters: @activity.parameters || {}
      }

      # A notification remains ticket-scoped, but its comment group must retain
      # every post it represents. Reactions can then consume the exact unread
      # group instead of marking unrelated ticket notifications as read.
      payload[:post_ids] = [@activity.secondary_id.to_s] if @activity.action == 'post_added' && @activity.secondary_type == 'Post'

      payload
    end
  end
end
