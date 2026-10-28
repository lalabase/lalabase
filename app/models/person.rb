# frozen_string_literal: true

# One person in the shared people directory of an organisation: a contact
# without a login, or the extra details of a member (user_id). Consultant and
# customer read and write the same rows, so nothing here is private (no
# internal notes, D1). A person who works for two customers is two rows, one
# per organisation (D3).
#
# name is always filled, also for a linked row (copied at link time by
# Actors::SavePerson), so removing the membership loses nothing
# (PersonLinkRelease). Tracking keeps no personal data (PersonTrackable).
# lock_version: both sides edit the same row; a stale save raises
# ActiveRecord::StaleObjectError.
class Person < ApplicationRecord
  # Declared BEFORE acts_as_tenant on purpose: acts_as_tenant 1.0.1 checks the
  # tenant of a reference only for associations declared before the call. The
  # link is validated on top (user_must_be_active_member), because a user has
  # no organisation_id of its own.
  belongs_to :user, optional: true
  belongs_to :creator, class_name: 'User', optional: true
  belongs_to :updater, class_name: 'User', optional: true

  acts_as_tenant(:organisation)

  include PersonTrackable

  MAX_NOTES_LENGTH = 10_000
  MAX_FIELD_LENGTH = 255
  TEXT_FIELDS = %i[name function department company email phone].freeze

  before_validation :normalize_name_fields

  validates :name, presence: true
  validates :normalized_name, presence: true
  validates(*TEXT_FIELDS, length: { maximum: MAX_FIELD_LENGTH })
  validates :notes, length: { maximum: MAX_NOTES_LENGTH }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :user_id, uniqueness: { scope: :organisation_id }, allow_nil: true
  validate :user_must_be_active_member, if: -> { user_id.present? && will_save_change_to_user_id? }

  scope :linked, -> { where.not(user_id: nil) }
  scope :unlinked, -> { where(user_id: nil) }
  scope :ordered, -> { order(:normalized_name, :id) }

  def linked?
    user_id.present?
  end

  # The membership behind the STORED link (not an unsaved change). While there
  # is one, the link stays (Actors::SavePerson, the form): deactivating can be
  # undone. An active one also owns name and email. Nil for a contact and for a
  # removed member (PersonLinkRelease).
  def stored_membership
    stored_id = user_id_in_database if persisted?
    Membership.find_by(organisation_id: organisation_id, user_id: stored_id) if stored_id
  end

  private

  def normalize_name_fields
    self.name = name.to_s.strip.gsub(/\s+/, ' ') if name
    self.normalized_name = PersonName.normalize(name)
  end

  # Same rule as Actors::SaveMeeting for participants: only an active member of
  # this organisation can be linked. A deactivated or foreign user is refused.
  def user_must_be_active_member
    member = Membership.where(organisation_id: organisation_id, user_id: user_id, active: true).exists?
    errors.add(:user, :not_an_active_member) unless member
  end
end
