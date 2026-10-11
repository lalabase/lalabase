# frozen_string_literal: true

# A request for the new-founder discount, declared by the applicant during
# registration (doc/billing_preisliste_rabatt_plan.md § 12.3).
#
# This is the REQUEST, not the grant -- the grant is an AccountDiscount created
# by hand in the admin backend after the phone call (§ 12.3.1). The two are
# deliberately separate: the request is what the customer stated, the discount
# is what we decided. Overwriting one with the other would lose the difference.
#
# The record blocks nothing (§ 12.3.4): registration completes, the customer
# works immediately, and the decision happens out of band. It also stays put
# when the request is DECLINED -- it is the evaluation table, and without the
# rejected cases half the statistics are missing.
#
# What the applicant declares is not verified. The phone call is the check,
# deliberately so: a programme demanding proof sends the opposite of the
# intended signal (§ 12.3.1).
# == Schema Information
#
# Table name: founder_signups
#
#  id                   :uuid             not null, primary key
#  company_name         :string           not null
#  company_seat         :string           not null
#  decided_at           :datetime
#  decided_by_email     :string
#  founded_on           :date             not null
#  marketing_consent    :boolean          default(FALSE), not null
#  marketing_consent_at :datetime
#  note                 :text
#  phone                :string           not null
#  previous_tools       :text
#  revenue_band         :string           not null
#  status               :string           default("open"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :uuid             not null
#
# Indexes
#
#  index_founder_signups_on_account_id             (account_id) UNIQUE
#  index_founder_signups_on_status_and_created_at  (status,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class FounderSignup < ApplicationRecord
  # Bands, never an exact figure (§ 12.3.2). For a sole trader the exact
  # turnover is a financial statement about a natural person; the band answers
  # the same question -- rough size before the call -- without that sharpness.
  REVENUE_BAND_UP_TO_50K = 'up_to_50k'
  REVENUE_BAND_50K_TO_250K = '50k_to_250k'
  REVENUE_BAND_250K_TO_1M = '250k_to_1m'
  REVENUE_BAND_ABOVE_1M = 'above_1m'

  REVENUE_BANDS = [
    REVENUE_BAND_UP_TO_50K,
    REVENUE_BAND_50K_TO_250K,
    REVENUE_BAND_250K_TO_1M,
    REVENUE_BAND_ABOVE_1M
  ].freeze

  STATUS_OPEN = 'open'
  STATUS_GRANTED = 'granted'
  STATUS_DECLINED = 'declined'

  STATUSES = [STATUS_OPEN, STATUS_GRANTED, STATUS_DECLINED].freeze

  # The fields the applicant fills in. Named here because three places need the
  # same list -- the form, the controller's strong-parameter slice and the
  # specs -- and a fourth would otherwise drift.
  DECLARED_ATTRIBUTES = %i[company_name company_seat founded_on revenue_band phone].freeze

  # How long an UNDECIDED request may keep its callback number. Without this the
  # number of someone nobody ever called would sit there forever -- the failure
  # mode a retention promise exists to prevent.
  CALLBACK_NUMBER_RETENTION = 3.months

  belongs_to :account

  validates :company_name, :company_seat, :founded_on, presence: true
  validates :revenue_band, inclusion: { in: REVENUE_BANDS }
  validates :status, inclusion: { in: STATUSES }
  validates :account_id, uniqueness: true

  # Required when the request is MADE, removable afterwards -- `on: :create` is
  # what makes the retention rule below possible without a second model.
  validates :phone, presence: true, on: :create

  # A founding date in the future is a typo, not a business case. Guarded
  # because the field is a free date input and the value later drives a
  # money-relevant decision.
  validate :founded_on_not_in_the_future

  scope :open_requests, -> { where(status: STATUS_OPEN).order(created_at: :desc) }

  # Requests whose callback number has served its purpose: decided, or never
  # decided and older than the retention window. Consent to sales contact keeps
  # the number -- that is a SEPARATE purpose under Art. 6 (1) a and ends with the
  # withdrawal, not with this decision.
  scope :callback_number_expired, lambda {
    where.not(phone: nil)
         .where(marketing_consent: false)
         .where('decided_at IS NOT NULL OR created_at < ?', CALLBACK_NUMBER_RETENTION.ago)
  }

  def open?
    status == STATUS_OPEN
  end

  def decided?
    !open?
  end

  # Drops the callback number and nothing else. Company name and seat stay:
  # they duplicate what accounts.name already holds under the contract, and the
  # remaining fields (band, founding date, status, tools) are what the request
  # exists to be evaluated on.
  #
  # NOT called "anonymise": the row still hangs off account_id and stays
  # attributable. Claiming otherwise in the privacy policy would be false.
  def drop_callback_number!
    update_column(:phone, nil)
  end

  private

  def founded_on_not_in_the_future
    return if founded_on.blank?
    return if founded_on <= Date.current

    errors.add(:founded_on, :in_the_future)
  end
end
