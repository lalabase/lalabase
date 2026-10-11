# frozen_string_literal: true

# == Schema Information
#
# Table name: ticket_assignments
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  ticket_id  :uuid             not null
#  user_id    :uuid             not null
#
# Indexes
#
#  index_ticket_assignments_on_ticket_id              (ticket_id)
#  index_ticket_assignments_on_ticket_id_and_user_id  (ticket_id,user_id) UNIQUE
#  index_ticket_assignments_on_user_id                (user_id)
#

class TicketAssignment < ApplicationRecord
  belongs_to :ticket
  belongs_to :user

  # Activity tracking for assignments is handled by SaveTicket → TicketTrackable,
  # NOT here, to avoid duplicate activities and GDPR-violating PII in parameters.

  # Auto-subscribe assignee when assigned to ticket
  after_create_commit :auto_subscribe_assignee
  # Auto-unsubscribe when unassigned from ticket
  after_destroy_commit :auto_unsubscribe_assignee

  private

  def auto_subscribe_assignee
    NotificationSubscription.system_subscribe(user: user, item: ticket, source: NotificationSubscription::SOURCE_ASSIGNEE)
  end

  def auto_unsubscribe_assignee
    sub = NotificationSubscription.find_by(user: user, subscribable: ticket)
    return unless sub&.mode_follow?

    # Keep subscription if user is also creator (with auto-follow setting)
    still_auto = ticket.creator_id == user.id && user.ticket_auto_follow_created?
    sub.destroy unless still_auto
  rescue StandardError => e
    Rails.logger.error "Failed to auto-unsubscribe: #{e.message}"
  end
end
