# frozen_string_literal: true

# Overview widget: the viewer's latest in-app notifications (newest first, all event types — not just
# mentions), each linking to its source. Replaces the old fixed unread hint that used to sit in the
# overview header. Recipient-scoped, so it always renders; the accessible_for scope still drops a
# notification whose source the viewer can no longer see. Unread rows are marked. Configurable limit.
class Overview::RecentNotificationsComponent < ViewComponent::Base
  def initialize(organisation:, user:, briefing:, limit: nil)
    @organisation = organisation
    @user = user
    # Part of the overview base_params contract; this widget queries notifications directly and does
    # not read the briefing, but stores it like the other overview components.
    @briefing = briefing
    @limit = limit
  end

  # Always renders — notifications are recipient-scoped (personal); none shows the in-card empty state.
  def should_render?
    true
  end

  private

  attr_reader :organisation, :user

  def effective_limit
    Dashboards::LayoutEngine.effective_item_limit('limit' => @limit)
  end

  def notifications
    @notifications ||= user.notifications
                           .channel_in_app
                           .where(organisation: organisation)
                           .accessible_for(user, organisation)
                           .recent
                           .includes(:actor, :notifiable, :project)
                           .limit(effective_limit)
  end

  # Human title for a notification, by event type (same i18n the inbox card uses), humanized fallback.
  def title_for(notification)
    t("notifications.titles.#{notification.event_type}", default: notification.event_type.to_s.humanize)
  end

  # "Who + where" sub-line so the row is actionable, not just "something happened": the actor and the
  # project, joined by a dot, each dropped when absent (system events have no actor; some events carry
  # no project). :actor/:project are preloaded above, so this adds no per-row query.
  def context_label(notification)
    actor_name = notification.actor && helpers.viewer_display_name(notification.actor)
    [actor_name, notification.project&.name].compact_blank.join(' · ')
  end

  # Link target for a notification's source, with a safe fall back to the inbox when the source is gone.
  def path_for(notification)
    if notification.notifiable
      helpers.notification_target_path(notification)
    else
      helpers.organisation_notifications_path(organisation_id: organisation.id)
    end
  end
end
