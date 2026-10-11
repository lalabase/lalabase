# frozen_string_literal: true

class RemoveMembershipService
  attr_reader :membership, :target_user, :admin, :organisation, :errors

  def initialize(membership:, admin:)
    @membership = membership
    @target_user = membership.user
    @admin = admin
    @organisation = membership.organisation
    @errors = []
  end

  def call
    return false unless valid?

    ActiveRecord::Base.transaction do
      # Remove the membership
      membership.destroy!

      # Check if user should be flagged for deletion review
      target_user.mark_for_deletion_review! if target_user.should_be_recommended_for_deletion?

      # Broadcast membership removal event
      broadcast_membership_removal_event

      true
    end
  rescue StandardError => e
    errors << e.message
    Rails.logger.error "Failed to remove membership #{membership.id}: #{e.message}"
    false
  end

  private

  def valid?
    unless admin.account_admin_in?(organisation)
      errors << 'You do not have permission to remove memberships from this organisation'
      return false
    end

    if target_user == admin
      errors << 'You cannot remove your own membership'
      return false
    end

    unless membership.persisted?
      errors << 'Membership does not exist'
      return false
    end

    if Memberships::LastAdminGuard.blocks?(membership, removing: true)
      errors << I18n.t('flash.memberships.last_active_admin', organisation: organisation.name)
      return false
    end

    true
  end

  def broadcast_membership_removal_event
    # Broadcasting through ActiveSupport::Notifications
    ActiveSupport::Notifications.instrument('membership.removed', {
                                              user_id: target_user.id,
                                              organisation_id: organisation.id,
                                              admin_id: admin.id,
                                              deletion_recommended: target_user.deletion_recommended?,
                                              removed_at: Time.current
                                            })

    Rails.logger.info "Membership removal event: User #{target_user.id} removed from organisation #{organisation.id} by admin #{admin.id}"
  end
end
