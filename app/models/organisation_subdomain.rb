# frozen_string_literal: true

# A subdomain an organisation is shown under (doc/org_subdomains_plan.md, S1). A row
# without held_until is the organisation's current subdomain; a row with it keeps an old
# name for the organisation until then, so nobody else can take it while old links still
# lead to it. An expired hold counts as absent.
#
# Not tenant-scoped on purpose: the host decides nothing about access, and it is read
# before any tenant is known (Organisations::Hosts). Only the instance admin writes it,
# through Actors::AssignOrganisationSubdomain.
class OrganisationSubdomain < ApplicationRecord
  # One DNS label: lower-case letters, digits and inner hyphens.
  FORMAT = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/
  LENGTH = (3..63)

  # Names that would pass for a part of the service, or that already are one.
  # Plus the names that mean something to a mail client or a browser under a wildcard
  # record (autodiscover, autoconfig, mta-sts, wpad), and names that pass for a sign-in.
  RESERVED = %w[
    account accounts admin api app assets auth autoconfig autodiscover billing blog cable
    cdn console demo dev docs download ftp help imap info lalabase login mail mcp
    mta-sts news ns ns1 ns2 operator pop root secure security signin smtp sso stage
    staging static stats status support test web webmail wpad www
  ].freeze

  HOLD_PERIOD = 90.days

  belongs_to :organisation

  normalizes :subdomain, with: ->(value) { value.to_s.strip.downcase }

  validates :subdomain, presence: true, length: { in: LENGTH }, format: { with: FORMAT }
  validates :subdomain, exclusion: { in: RESERVED }
  validates :subdomain, uniqueness: true
  validate :no_encoded_label

  scope :current, -> { where(held_until: nil) }
  scope :held, -> { where.not(held_until: nil).where(held_until: Time.current..) }
  scope :expired, -> { where.not(held_until: nil).where(held_until: ...Time.current) }

  def current?
    held_until.nil?
  end

  private

  # Two hyphens at the third and fourth place mark an encoded label (`xn--...`), which a
  # browser shows as other letters: `xn--mnchen-3ya` reads `münchen`, and a lookalike of
  # another customer's name would get through.
  def no_encoded_label
    errors.add(:subdomain, :encoded) if subdomain.to_s[2, 2] == '--'
  end
end
