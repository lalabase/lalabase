# frozen_string_literal: true

class NeoMobileNavComponent < ViewComponent::Base
  def initialize(user:, organisation:, current_project: nil)
    @user = user
    @organisation = organisation
    @current_project = current_project
  end

  private

  attr_reader :user, :organisation, :current_project

  def show_notifications?
    user.present? && organisation.present?
  end

  # The inbox rule (Notification.inbox_unread), the same number the live badge
  # broadcast writes into this marker afterwards.
  def unread_count
    @unread_count ||= user.unread_notifications_count(organisation)
  end
end
