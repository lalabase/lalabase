# frozen_string_literal: true

# Overview widget (1 unit): a compact count of the viewer's unread in-app notifications, linking to
# the inbox. Thin wrapper around the shared Dashboard::DailyBriefing#unread_notifications_count.
#
# Always renders (permission: nil — every member has notifications); zero unread shows the calm
# all-caught-up state inside the card rather than hiding the widget. Reuses the hero's unread i18n
# (dashboard.briefing.*) so the wording stays in one place.
class Overview::UnreadSummaryComponent < ViewComponent::Base
  def initialize(organisation:, user:, briefing:)
    @organisation = organisation
    @user = user
    @briefing = briefing
  end

  # Always renders; zero unread shows the calm all-caught-up state inside the card.
  def should_render?
    true
  end

  private

  attr_reader :organisation, :user, :briefing

  def unread_count
    @unread_count ||= briefing.unread_notifications_count
  end
end
