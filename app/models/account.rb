# frozen_string_literal: true

# == Schema Information
#
# Table name: accounts
#
#  id                                  :uuid             not null, primary key
#  acquisition                         :jsonb
#  billing_addressee                   :string
#  billing_city                        :string
#  billing_country                     :string(2)
#  billing_email                       :string
#  billing_email_cc                    :string
#  billing_interval                    :string           default("monthly"), not null
#  billing_name                        :string
#  billing_postal_code                 :string
#  billing_reference                   :string
#  billing_region                      :string
#  billing_starts_on                   :date
#  billing_street                      :string
#  billing_street_2                    :string
#  business_confirmation_version       :string
#  business_confirmed_at               :datetime
#  guest_max_organisations             :integer          default(1), not null
#  guest_max_projects_per_organisation :integer          default(1), not null
#  name                                :string           not null
#  payment_terms_days                  :integer          default(14), not null
#  plan_key                            :string           default("cloud"), not null
#  vat_id_checked_at                   :datetime
#  vat_id_checked_name                 :string
#  vat_id_status                       :string           default("unchecked"), not null
#  created_at                          :datetime         not null
#  updated_at                          :datetime         not null
#  business_confirmed_by_id            :uuid
#  owner_id                            :uuid
#  vat_id                              :string
#
# Indexes
#
#  index_accounts_on_billing_starts_on         (billing_starts_on)
#  index_accounts_on_business_confirmed_by_id  (business_confirmed_by_id)
#  index_accounts_on_owner_id                  (owner_id)
#
# Foreign Keys
#
#  fk_rails_...  (business_confirmed_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (owner_id => users.id) ON DELETE => nullify
#
# Billing identity above organisation (plan doc/billing_agentur_konto_plan.md D2).
# Account deliberately stays a pure billing entity, with no self-reference to
# organisation (D2) -- being the owner implies NO access to org data (D4).
class Account < ApplicationRecord
  # Raised by #claim! -- no controller/UI consumes this yet in Phase 1, so a
  # plain domain error is enough (no i18n scaffolding for an exception with no
  # current caller).
  class AlreadyClaimedError < StandardError; end

  # E4: the authoritative check runs at Stripe (VIES for the EU, HMRC for the
  # UK) and arrives back via the customer.tax_id.updated webhook in the Stripe
  # phase. Until then every row sits at `unchecked`; nothing in this phase ever
  # sets anything else.
  VAT_ID_STATUSES = { unchecked: 'unchecked', pending: 'pending',
                      valid: 'valid', invalid: 'invalid' }.freeze

  belongs_to :owner, class_name: 'User', optional: true
  # WHO confirmed the business status at checkout (E8). Not the owner by
  # definition: the owner can change via claim! after the confirmation.
  belongs_to :business_confirmed_by, class_name: 'User', optional: true
  has_many :organisations, dependent: :restrict_with_exception
  # Special conditions granted in the admin backend only (D3 of
  # doc/billing_preisliste_rabatt_plan.md) -- destroyed with the account,
  # unlike organisations, because a discount has no meaning without it.
  has_many :discounts, class_name: 'AccountDiscount', dependent: :destroy, inverse_of: :account
  # The new-founder request from registration (§ 12.3.4). At most one per
  # account, and it is the REQUEST -- the granted discount is one of the
  # `discounts` above. Destroyed with the account for the same reason.
  has_one :founder_signup, dependent: :destroy, inverse_of: :account

  # Accounts whose recorded origin has outlived its retention (privacy policy
  # § 4.2). Anchored on created_at, not on the stored first_seen_at: the latter
  # is missing on every row written before that key existed, and a row without a
  # timestamp must not become one that never expires.
  scope :acquisition_expired, lambda {
    where.not(acquisition: nil).where(created_at: ...AcquisitionSource::RETENTION.ago)
  }

  # prefix is mandatory, not cosmetic: without it the `valid` value would
  # generate `Account#valid?` and silently shadow ActiveRecord's own. The long
  # name is also the honest one, because it separates the two questions that are
  # easy to confuse: `vat_id_status_valid?` means "Stripe verified this number",
  # not "the number is syntactically well formed".
  enum :vat_id_status, VAT_ID_STATUSES, prefix: true, default: :unchecked, validate: true

  before_validation :normalise_billing_fields
  before_validation :reset_vat_id_verification, if: :vat_id_changed?

  validates :name, presence: true
  validates :billing_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :billing_email_cc, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :guest_max_organisations,
            presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :guest_max_projects_per_organisation,
            presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :billing_country, inclusion: { in: ISO3166::Country.codes }, allow_blank: true

  # CONTEXT-FREE on purpose (E4): a syntactically broken VAT ID must never reach
  # the database, no matter which path writes it. Scoped to the countries valvat
  # can actually check, because for CH, AU, IN or CA it would reject VALID ids.
  validate :vat_id_format

  # E3, all-or-nothing. An owner may clear the billing details completely, but
  # must not leave them half filled. `unless:` on the declarative validations is
  # what makes that work: an early return inside a custom validate block would
  # end only itself, and the declarative ones would fire regardless, so the
  # owner could never delete their data again.
  with_options on: :billing, unless: :billing_fields_all_blank? do
    Accounts::BillingRules::REQUIRED_FIELDS.each do |field|
      validates field, presence: true
    end

    validate :billing_region_required_for_country
    validate :vat_id_required_for_country
  end

  # Billing state (W3 of doc/billing_rechnungsstellung_r1_plan.md, E2). Three
  # columns instead of a Subscription model: under R1 the payment happens
  # outside the application, so there is exactly one lifecycle state.
  #
  # OPERATOR FIELDS, not customer fields -- the same class of special condition
  # as guest_max_* and AccountDiscount. Permitted in Admin::AccountsController
  # only. When the customer-facing billing page arrives (W6/B4) it must NOT
  # permit them: a customer setting their own billing start date would be
  # writing their own invoice.
  validates :billing_interval, inclusion: { in: Subscriptions::Constants::BILLING_INTERVAL_KEYS }
  # The booked plan (§13 of doc/billing_preisliste_rabatt_plan.md), an operator
  # field like the interval. Booked, not enforced: the AI code never reads it.
  validates :plan_key, inclusion: { in: Subscriptions::Constants::PLAN_KEYS }
  validates :payment_terms_days,
            presence: true, numericality: { only_integer: true, greater_than: 0 }
  validate :billing_starts_on_must_be_parsable
  # Only while one of the two values is actually being written. A rule that also
  # judges rows at rest would make every EXISTING row with an over-long term
  # permanently invalid, and then block writes that have nothing to do with it:
  # changing the guest ceilings, or `claim!`, which does an `update!` and would
  # raise instead of assigning an owner. The form shipped without an upper bound,
  # so such rows can exist. This way the ceiling stops a bad value from being
  # SET, which is the whole intent, and never punishes a row for its past.
  #
  # `billing_interval_changed?` matters as much as the term itself: moving an
  # account from yearly to monthly is the other way a legal pair turns illegal.
  validate :payment_terms_days_within_billing_period,
           if: -> { payment_terms_days_changed? || billing_interval_changed? }

  # D3: 1:1 auto-backfill for organisations that predate the ensure_account
  # callback (T3) -- no grouping guess (a false-positive grouping would be a
  # privacy-shaped risk, not cosmetic). Idempotent by construction: a second
  # run finds zero matching organisations, since the first run already set
  # every account_id.
  def self.backfill_all!
    count = 0
    Organisation.where(account_id: nil).find_each do |org|
      org.update!(account: Account.new(name: org.name))
      count += 1
    end
    count
  end

  # Has a billing start been DECIDED for this account? NULL means "not
  # clarified", NOT "free": deliberately free is a 100 % AccountDiscount (plan
  # E4), so a forgotten account and a decided-to-be-free one never look the
  # same. The billing list shows the NULLs in their own "unclear" section for
  # exactly that reason.
  #
  # The name is third try, and both earlier ones were near-misses worth naming:
  #
  # `billed?` collided with TimeSession#billed? / TimeSessionGroup#billed?, which
  # carry the OPPOSITE direction of money here (the customer invoiced their own
  # client). `billing_started?` reads as past tense and would answer true for a
  # start date 30 days out, so a caller in the W4/W5 invoice run could read
  # "billing has started" and invoice a period that has not begun.
  #
  # This name claims no point in time at all, only that the decision was made --
  # which is exactly the E4 distinction between "decided" and "not clarified".
  # Whether the date has ARRIVED is a separate question and belongs to W4, which
  # must compare against a reference date rather than call this.
  def billing_start_decided?
    billing_starts_on.present?
  end

  # D11: an owner-less Account (factories/rake tasks/Admin backend, D8) must
  # not stay permanently unmanageable, since only the owner can manage
  # billing/roles (D4/D10). Whether `user` is ALLOWED to claim (account_admin
  # in one of the account's organisations) is an authorization question,
  # checked separately via AccountPolicy#claim? -- this method only enforces
  # the domain invariant that an already-owned Account cannot be re-claimed.
  def claim!(user)
    # A nil user would slip through the owner-check below and "succeed" as a
    # silent no-op claim (update!(owner: nil)) -- fail loudly instead.
    raise ArgumentError, 'user is required' if user.nil?

    # with_lock wraps the check + write in one transaction with a row lock
    # (SELECT ... FOR UPDATE), so two account_admins of different
    # organisations in the same account cannot both read "no owner yet" and
    # both succeed -- the second one blocks until the first commits, then
    # correctly sees an owner and raises. Without this, a plain read-then-
    # write race would let the second claim!  silently overwrite the first
    # owner instead of raising AlreadyClaimedError.
    with_lock do
      raise AlreadyClaimedError, "Account #{id} already has an owner (#{owner_id})" if owner.present?

      update!(owner: user)
    end
  end

  # N4 (doc/billing_stammdaten_plan.md § 18): the operator counterpart to #claim!,
  # which may replace an EXISTING owner.
  #
  # Deliberately a method of its own instead of softening claim!. Its
  # AlreadyClaimedError protects the CUSTOMER claim path against the race in which
  # two account_admins read "no owner yet" at the same time; whoever removes the error
  # there to get further here turns a protected path into a silent
  # overwrite.
  #
  # Without this path there is a dead end: if the owner loses their
  # membership or is set to active: false (not deleted, so the
  # nullify safety net does not apply), the account is no longer reachable
  # for them and invisible to everyone else.
  #
  # Deliberately overwrites without a precondition on the previous owner: that
  # IS the purpose. Who is entitled is decided by the caller through
  # #eligible_owner? -- the same rule as for assigning, so the operator does not
  # give the account to anyone who can never sign in. The previous owner
  # is returned so the message can say WHAT was swapped.
  def reassign_owner!(user)
    raise ArgumentError, 'user is required' if user.nil?

    # The same lock as in claim!: two operator tabs must not overtake
    # each other, and the returned predecessor must be the one that
    # was really replaced, not one from a stale read.
    with_lock do
      previous = owner
      update!(owner: user)
      previous
    end
  end

  # D11: surfaced in the Admin-Backend (§4.4) as an "Orphan"-Badge so Lalabase
  # staff can see which Accounts still need a claim.
  #
  # `owner.nil?`, NOT `owner_id.nil?` (N3): AccountPolicy#claim? and #claim!
  # both test `owner`, which is scoped by SoftDeletable. With the id check those
  # three disagreed for a soft-deleted owner: the customer saw the claim banner
  # and could take over, while the operator's badge still read "has an owner".
  # Users in this app are NEVER hard-deleted, so that is the normal case rather
  # than an edge one.
  def orphan?
    owner.nil?
  end

  # A DIFFERENT question from orphan?, and the two are easy to confuse: this one
  # is about organisations, that one about the owner. An account can be either,
  # both or neither.
  #
  # Named here because two surfaces already ask it and they must not drift:
  # Subscriptions::AccountSummaries hides such an account from the customer (K7
  # of doc/konto_ebene_plan.md), and the admin list labels it instead of hiding
  # it. Same fact, two deliberately opposite answers -- which only stays
  # deliberate while both read the same predicate.
  #
  # Drained is NOT deletable and not meant to be: after a move the seat and
  # usage history keeps this account_id (K6), so this row is where the billing
  # basis for the period BEFORE the move hangs. K7 keeps it, and the foreign
  # keys on seat_events/seat_snapshots/ai_usage_rollups would refuse anyway.
  #
  # Reads the association, so a preloaded one costs no query -- which is what
  # AccountSummaries relies on.
  def without_organisations?
    organisations.empty?
  end

  # The postal address as a value object (§5). Cheap to build, so no memoisation
  # that could go stale after an update.
  def billing_address
    Accounts::BillingAddress.new(self)
  end

  # Badge in the UI and precondition for the later checkout. Deliberately not
  # `valid?(:billing)`: this asks about the DATA, not about a save attempt, and
  # it must stay answerable for a record that is invalid for other reasons.
  def billing_complete?
    return false if Accounts::BillingRules::REQUIRED_FIELDS.any? { |field| public_send(field).blank? }
    return false if billing_region_missing?

    !vat_id_missing?
  end

  # Is there anything to SHOW? The third of three billing predicates, and the three ask
  # genuinely different questions:
  #
  #   #billing_complete?         -- may an invoice be written from this? (REQUIRED_FIELDS)
  #   #billing_fields_all_blank? -- may the form be saved empty?         (REQUIRED_FIELDS)
  #   #billing_details_present?  -- is there anything on the page?       (ALL fields)
  #
  # The wider set is the point. Both display surfaces used to gate on "address or e-mail",
  # which swallows billing_reference and billing_email_cc: those belong to neither, they are
  # OPTIONAL_FIELDS a customer can save on their own, and they skip the :billing validation
  # entirely (it only fires once a REQUIRED field is filled). An account carrying nothing but
  # a customer reference was therefore told "no billing details on file" while looking at
  # data it had just saved.
  def billing_details_present?
    Accounts::BillingRules::PERMITTED_FIELDS.any? { |field| public_send(field).present? }
  end

  # The "nothing filled in at all" state that makes clearing possible (E3).
  def billing_fields_all_blank?
    Accounts::BillingRules::REQUIRED_FIELDS.all? { |field| public_send(field).blank? }
  end

  # Candidates for owning this Account, grouped by organisation for the
  # org-grouped operator UI (§4.4). A candidate is an ACTIVE account_admin of one
  # of the account's organisations (same rule as AccountPolicy#claim?/W1), AND is
  # globally active + not soft-deleted (D9) -- otherwise staff could hand billing
  # ownership to a user who can never sign in, leaving an unmanageable Account with
  # NO orphan badge to flag it. A user who is admin in several of the account's
  # orgs appears once per org. Orgs with no eligible admin map to an empty array.
  #
  # Per-org with_tenant is mandatory: Role is acts_as_tenant(:organisation) while
  # Membership is not, so membership.role only resolves the account_admin role
  # under the organisation's own tenant -- not whatever tenant is active when this
  # runs (usually none, in the tenant-less admin backend).
  def eligible_owners_by_organisation
    organisations.each_with_object({}) do |org, result|
      ActsAsTenant.with_tenant(org) do
        result[org] = org.memberships.active.includes(:user, :role).filter_map do |membership|
          membership.user if eligible_membership?(membership)
        end
      end
    end
  end

  # Single source of truth for "may this user own this Account" -- used by the
  # Admin controller guard (assign_owner) AND AccountPolicy#claim?. Same rule as
  # #eligible_owners_by_organisation, short-circuited via any?. See that method for
  # why each organisation is checked under its own tenant (D9/W1).
  def eligible_owner?(user)
    # Hoist the org-independent D9 invariants above the per-org DB loop: a
    # globally inactive or soft-deleted user can never be eligible, so return
    # without issuing a single membership query per organisation.
    return false if user.nil? || !user.active? || user.deleted_at.present?

    organisations.any? do |org|
      ActsAsTenant.with_tenant(org) do
        eligible_membership?(org.memberships.active.find_by(user_id: user.id))
      end
    end
  end

  private

  # A date column casts an unparsable string to nil, silently. And nil is not a
  # neutral value here: it is the E4 marker for "not clarified". So a typo'd date
  # would land as "this account has not been decided about" instead of failing --
  # exactly the ambiguity the three billing columns exist to prevent, reached
  # through the one path that writes them.
  #
  # The browser date field cannot produce this (it submits a valid date or an
  # empty string); a direct PATCH can. Operator reach, not customer reach, which
  # is why this is a validation rather than something louder.
  #
  # An empty string stays legal: clearing the field back to "not clarified" is a
  # deliberate operator action, and only a NON-blank input that vanished on cast
  # is a mistake.
  def billing_starts_on_must_be_parsable
    return if billing_starts_on.present?

    raw = billing_starts_on_before_type_cast
    return unless raw.is_a?(String) && raw.present?

    errors.add(:billing_starts_on, :invalid)
  end

  # § 7 of the terms makes fees due IN ADVANCE for the billing period. A payment
  # term longer than the period itself makes that structurally impossible: the
  # invoice for one monthly period would only fall due once the next has already
  # started, and the billing list would show a debt that is not yet a debt.
  #
  # The ceiling is NOT invented -- it comes from the registry, so a third
  # interval brings its own bound with it. DAYS_PER_MONTH_APPROX is deliberately
  # generous: this catches a typo (60 days on a monthly account), it does not
  # enforce an accounting rule.
  #
  # Skipped for an interval outside the registry, because `months_for` raises
  # there by design; the inclusion validation above already reports that case,
  # and one mistake should produce one message.
  def payment_terms_days_within_billing_period
    return if payment_terms_days.blank?
    # One mistake, one message -- the same courtesy the unknown-interval branch
    # below gets. `numericality` runs first and already rejects "60abc"; adding
    # "and it is above the ceiling" on top describes a number the operator never
    # typed, because the cast invented the 60.
    return if errors[:payment_terms_days].any?
    return unless Subscriptions::Constants::BILLING_INTERVAL_KEYS.include?(billing_interval)

    ceiling = Subscriptions::Constants.months_for(billing_interval) *
              Subscriptions::Constants::DAYS_PER_MONTH_APPROX
    return if payment_terms_days <= ceiling

    errors.add(:payment_terms_days, :less_than_or_equal_to, count: ceiling)
  end

  # Normalising BEFORE validation is what makes the country and VAT checks
  # meaningful: "de" and "DE 123 456 789" are the same values a human types.
  def normalise_billing_fields
    billing_country&.upcase!
    vat_id&.gsub!(/[\s.]/, '')
    vat_id&.upcase!
    # URI::MailTo::EMAIL_REGEXP is anchored with \A…\z, so a pasted address with
    # a leading space is rejected as "invalid" while looking correct to the
    # person who pasted it.
    billing_email&.strip!
    billing_email_cc&.strip!
  end

  # E4, mandatory: a changed VAT ID invalidates whatever Stripe told us about
  # the old one. Without this the support screen would show "valid" for a number
  # nobody ever checked. It belongs here and not in the Stripe phase, because
  # the write path that breaks it already exists in B3.
  def reset_vat_id_verification
    self.vat_id_status = :unchecked
    self.vat_id_checked_at = nil
    self.vat_id_checked_name = nil
  end

  # valvat's #valid? is a pure SYNTAX check, so a made-up DE123456789 passes it.
  # #valid_checksum? covers syntax AND the check digit, and returns true for
  # countries that have no checksum algorithm, which is the safe direction.
  #
  # The number is validated as a STRING, never against billing_country: Greece
  # is the country code GR but its VAT ids start with EL, so comparing the two
  # would reject every Greek customer.
  def vat_id_format
    return unless Accounts::BillingRules.vat_format_checkable?(vat_id)
    return if Valvat.new(vat_id).valid_checksum?

    errors.add(:vat_id, :invalid_format)
  end

  def billing_region_required_for_country
    errors.add(:billing_region, :blank) if billing_region_missing?
  end

  # E11: an EU customer outside Germany without a VAT ID has to be treated like
  # a non-business, which means local VAT and an OSS registration. Requiring the
  # id is the decision taken instead (§3/E11).
  def vat_id_required_for_country
    errors.add(:vat_id, :blank) if vat_id_missing?
  end

  def billing_region_missing?
    Accounts::BillingRules.region_required?(billing_country) && billing_region.blank?
  end

  def vat_id_missing?
    Accounts::BillingRules.vat_id_required?(billing_country) && vat_id.blank?
  end

  # The single eligibility rule (D9/W1), shared by both public methods so a rule
  # change lands in one place. A candidate is an active account_admin membership
  # whose user is globally active and not soft-deleted. `membership.user` is
  # already nil for a soft-deleted user (User is SoftDeletable default-scoped);
  # the deleted_at guard is belt-and-suspenders for any unscoped edge.
  def eligible_membership?(membership)
    return false if membership.nil?
    return false unless membership.role&.account_admin?

    user = membership.user
    user&.active? && user.deleted_at.nil?
  end
end
