# frozen_string_literal: true

# Overview widget: the viewer's recent unread @-mentions (Notification event_type 'mention'), newest
# first. Personal and recipient-scoped, so it always renders (no permission gate); the accessible_for
# scope still drops a mention whose source the viewer can no longer see. Configurable item limit.
class Overview::MyMentionsComponent < ViewComponent::Base
  def initialize(organisation:, user:, briefing:, limit: nil)
    @organisation = organisation
    @user = user
    # Part of the overview base_params contract; this widget queries notifications directly and does
    # not read it, but stores it like the other overview components.
    @briefing = briefing
    @limit = limit
  end

  # Always renders — mentions are recipient-scoped (personal); zero shows the in-card empty state.
  def should_render?
    true
  end

  private

  attr_reader :organisation, :user

  def effective_limit
    Dashboards::LayoutEngine.effective_item_limit('limit' => @limit)
  end

  def mentions
    @mentions ||= user.notifications
                      .channel_in_app
                      .where(organisation: organisation)
                      .mentions
                      .unread
                      .accessible_for(user, organisation)
                      .recent
                      .includes(:actor, :notifiable)
                      .limit(effective_limit)
  end
end
