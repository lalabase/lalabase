# frozen_string_literal: true

# == Schema Information
#
# Table name: invitations
#
#  id              :uuid             not null, primary key
#  accepted_at     :datetime
#  email           :string
#  sent_at         :datetime
#  token           :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  inviter_id      :uuid             not null
#  organisation_id :uuid             not null
#
# Indexes
#
#  index_invitations_on_organisation_id  (organisation_id)
#  index_invitations_on_token            (token) UNIQUE
#
class Invitation < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :inviter, class_name: 'User', optional: true

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :token, uniqueness: true, presence: true

  before_validation :generate_token, on: :create

  # How long a sent invitation stays acceptable. The single owner of the
  # threshold that out_of_date? and the redeemable scope both read, so the
  # instance check and the SQL check cannot drift apart.
  VALIDITY = 3.days

  scope :pending, -> { where(accepted_at: nil) }
  # Still open AND still in its TTL, i.e. somebody can actually accept it. The
  # SQL twin of `!out_of_date? && accepted_at.nil?` (the controller's
  # valid_invitation). A nil sent_at falls outside the range, so it is excluded,
  # exactly like out_of_date? treats it.
  scope :redeemable, -> { pending.where(sent_at: VALIDITY.ago..) }

  attr_accessor :terms_accepted

  def accepted?
    accepted_at.present?
  end

  # The ONLY expiry gate for token registrations (Users::RegistrationsController
  # calls this on GET new and POST create). Conservative on nil: an invitation
  # that was never sent has nothing proving its freshness, so its token must
  # not work — and `nil < time` would crash the registration otherwise.
  def out_of_date?
    sent_at.nil? || sent_at < VALIDITY.ago
  end

  # The invited address the way Devise stores it (strip_whitespace_keys,
  # case_insensitive_keys). The single owner of the comparison, so the three
  # invitation paths cannot disagree about whether an address is the invited one.
  def normalized_email
    email.to_s.strip.downcase
  end

  def addressed_to?(other_email)
    normalized_email.present? && normalized_email == other_email.to_s.strip.downcase
  end

  private

  def generate_token
    self.token ||= SecureRandom.hex(10)
  end
end
