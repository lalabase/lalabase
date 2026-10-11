# frozen_string_literal: true

# Syncs a ticket's assignees to the submitted assignee_ids: applies the add/remove
# delta with batch writes (avoiding per-record callback N+1), keeps the assignees'
# notification subscriptions in step, and tracks the assigned/unassigned activities.
#
# Extracted from Actors::SaveTicket#handle_assignments. Self-contained — it does no
# job enqueuing (the subscription and activity work is synchronous), so unlike
# TicketDocumentSync it returns nothing. It relies on Current.user being set by the
# caller (Actors::BaseActor#with_actor_context) for activity attribution.
#
# Security: assignee_ids are filtered through Ticket#assignable_user_ids — org
# membership alone is insufficient; project-foreign org members must not become
# assignable via param tampering.
class TicketAssignmentSync
  # extra_activity_parameters is threaded into the assigned/unassigned
  # activities (e.g. skip_email for onboarding seed assignments, read by
  # FanoutService#determine_channels_for_recipient) — keeps the seed on this
  # single sync path instead of a duplicate activity-creation path.
  def self.call(ticket:, assignee_ids:, is_new_ticket:, extra_activity_parameters: {})
    new(ticket: ticket, assignee_ids: assignee_ids, is_new_ticket: is_new_ticket,
        extra_activity_parameters: extra_activity_parameters).call
  end

  def initialize(ticket:, assignee_ids:, is_new_ticket:, extra_activity_parameters: {})
    @ticket = ticket
    @assignee_ids = assignee_ids
    @is_new_ticket = is_new_ticket
    @extra_activity_parameters = extra_activity_parameters
  end

  def call
    old_ids = current_assignee_ids
    new_ids = requested_assignee_ids

    # Batch the writes to avoid N+1 in callbacks, then track the change explicitly.
    sync_assignments(old_ids, new_ids)
    track_assignment_changes(old_ids, new_ids)
  end

  private

  def current_assignee_ids
    return Set.new if @is_new_ticket

    @ticket.ticket_assignments.pluck(:user_id).to_set
  end

  # Only users with access to this ticket's project may be assigned. Single source:
  # Ticket#assignable_user_ids.
  def requested_assignee_ids
    return Set.new if @assignee_ids.blank?

    @ticket.assignable_user_ids(@assignee_ids).to_set
  end

  def sync_assignments(old_assignee_ids, new_assignee_ids)
    added_ids = new_assignee_ids - old_assignee_ids
    removed_ids = old_assignee_ids - new_assignee_ids

    # Remove old assignments (delete_all skips per-record callbacks)
    if removed_ids.any?
      @ticket.ticket_assignments.where(user_id: removed_ids.to_a).delete_all
      batch_unsubscribe_assignees(removed_ids)
    end

    # Add new assignments (insert_all skips per-record callbacks)
    if added_ids.any?
      now = Time.current
      # Batch insert by design — per-record callbacks are intentionally skipped
      # (subscriptions/activity are handled in bulk below) to avoid N+1.
      TicketAssignment.insert_all!(
        added_ids.map { |uid| { ticket_id: @ticket.id, user_id: uid, created_at: now, updated_at: now } }
      )
      batch_subscribe_assignees(added_ids)
    end

    # Reset association caches
    @ticket.association(:ticket_assignments).reset
    @ticket.association(:assignees).reset
  end

  def batch_subscribe_assignees(user_ids)
    existing = NotificationSubscription.where(user_id: user_ids.to_a, subscribable: @ticket)
                                       .index_by(&:user_id)
    user_ids.each do |uid|
      sub = existing[uid]
      next if sub&.mode == 'follow'
      next if sub&.mode_mute?

      if sub
        sub.update_column(:mode, 'follow')
      else
        NotificationSubscription.new(
          user_id: uid,
          subscribable: @ticket,
          organisation_id: @ticket.organisation_id,
          mode: 'follow',
          source: NotificationSubscription::SOURCE_ASSIGNEE
        ).save!(validate: false)
      end
    end
  end

  def batch_unsubscribe_assignees(user_ids)
    subs = NotificationSubscription.where(user_id: user_ids.to_a, subscribable: @ticket, mode: 'follow')
    return if subs.empty?

    # Only keep subscription if user is creator with auto-follow setting
    creator_has_auto_follow = @ticket.creator_id.present? &&
                              user_ids.include?(@ticket.creator_id) &&
                              User.find_by(id: @ticket.creator_id)&.ticket_auto_follow_created?

    subs.each do |sub|
      next if sub.user_id == @ticket.creator_id && creator_has_auto_follow

      sub.destroy
    end
  end

  def track_assignment_changes(old_assignee_ids, new_assignee_ids)
    return if @ticket.respond_to?(:track_activities?, true) && !@ticket.send(:track_activities?)

    added_ids = new_assignee_ids - old_assignee_ids
    removed_ids = old_assignee_ids - new_assignee_ids

    return unless added_ids.any? || removed_ids.any?

    # Preload all affected users with memberships+roles to avoid N+1
    users_by_id = User.where(id: (added_ids + removed_ids).to_a)
                      .includes(memberships: :role)
                      .index_by(&:id)

    # Ensure organisation is loaded once for activity creation (avoids N+1 in outbox)
    @ticket.organisation

    removed_ids.each do |uid|
      user = users_by_id[uid]
      next unless user

      @ticket.track_assignee_removed(user, @extra_activity_parameters)
    end

    added_ids.each do |uid|
      user = users_by_id[uid]
      next unless user

      @ticket.track_assignee_added(user, @extra_activity_parameters)
    end
  end
end
