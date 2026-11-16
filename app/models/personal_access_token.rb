# frozen_string_literal: true

# == Schema Information
#
# Table name: personal_access_tokens
#
#  id                :uuid             not null, primary key
#  all_organisations :boolean          default(FALSE), not null
#  expires_at        :datetime         not null
#  kind              :string           default("personal"), not null
#  last_used_at      :datetime
#  name              :string           not null
#  read_only         :boolean          default(TRUE), not null
#  revoked_at        :datetime
#  token_hash        :string           not null
#  token_prefix      :string(12)       not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  user_id           :uuid             not null
#
# Indexes
#
#  index_personal_access_tokens_on_token_hash              (token_hash) UNIQUE
#  index_personal_access_tokens_on_user_id                 (user_id)
#  index_personal_access_tokens_on_user_id_and_created_at  (user_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class PersonalAccessToken < ApplicationRecord
  TOKEN_PREFIX = 'lalab_pat_'
  TOKEN_BODY_LENGTH = 32
  TOKEN_PREFIX_DISPLAY_LENGTH = 12
  # The longest a token may live. A token outlives the session it was made in,
  # so this is how long a stolen session can keep reading after it was ended.
  MAX_LIFETIME = 90.days

  # Who made the token. `personal`: its owner, on the token page, with a reach and
  # an expiry of their choice. `app_session`: the sign-in door, for one device
  # (its name is the device's). A device token always reaches the whole account
  # and may write, and it lives while the device is used: every use moves
  # expires_at to MAX_LIFETIME from now (#record_use!), never past
  # APP_SESSION_MAX_AGE after it was made (#ends_at). A personal token never moves.
  KINDS = %w[personal app_session].freeze
  APP_SESSION = 'app_session'
  APP_SESSION_MAX_AGE = 365.days
  # Live device tokens per account. One more revokes the device unused longest
  # (.make_room_for_app_session!), so a password cannot mint tokens without end.
  MAX_APP_SESSIONS = 10

  belongs_to :user

  has_many :personal_access_token_organisations, dependent: :destroy, inverse_of: :personal_access_token
  # The organisations ticked when the token was MADE (its link rows), for display and
  # setup. Not what the token reaches: that is #organisation_scopes, which also knows
  # all_organisations (no link rows at all) and drops organisations the owner left.
  has_many :configured_organisations,
           through: :personal_access_token_organisations,
           source: :organisation

  has_many :personal_access_token_projects, dependent: :destroy, inverse_of: :personal_access_token
  has_many :scoped_projects,
           through: :personal_access_token_projects,
           source: :project

  accepts_nested_attributes_for :personal_access_token_organisations, allow_destroy: true
  accepts_nested_attributes_for :personal_access_token_projects, allow_destroy: true

  validates :name, presence: true, length: { maximum: 255 }
  validates :token_hash, presence: true, uniqueness: true
  validates :token_prefix, presence: true, length: { maximum: 12 }
  validates :expires_at, presence: true
  # On create only: tokens made before the limit keep working until they expire.
  validate :expires_within_max_lifetime, on: :create
  validates :kind, inclusion: { in: KINDS }
  validate :app_session_reaches_the_account_and_writes
  validate :must_have_at_least_one_organisation_scope
  validate :no_organisation_links_with_all_organisations
  validate :scoped_projects_must_belong_to_scoped_organisations

  scope :active, lambda {
    where(revoked_at: nil).where('expires_at > ?', Time.current)
  }

  scope :app_sessions, -> { where(kind: APP_SESSION) }

  attr_reader :token

  # Finds an active token by its plaintext string.
  # Returns nil for an invalid format, or expired or revoked tokens.
  def self.authenticate(plaintext)
    return nil if plaintext.blank?
    return nil unless plaintext.start_with?(TOKEN_PREFIX)

    digest = Digest::SHA256.hexdigest(plaintext)
    active.find_by(token_hash: digest)
  end

  # Generates a plaintext token and sets the derived fields, WITHOUT saving.
  # Useful when the controller wants to save the token + scope links in one transaction.
  def assign_token!
    raw = "#{TOKEN_PREFIX}#{SecureRandom.alphanumeric(TOKEN_BODY_LENGTH)}"
    self.token_hash = Digest::SHA256.hexdigest(raw)
    self.token_prefix = raw.first(TOKEN_PREFIX_DISPLAY_LENGTH)
    @token = raw
  end

  # Generates + saves a new plaintext token.
  # The plaintext is afterwards available via #token (this instance only!).
  def generate_token!
    assign_token!
    save!
    @token
  end

  # Every live token of the user, e.g. after a password change: whoever held
  # the account before may have minted one. update_all on purpose, one query
  # and no callbacks; the account erasure uses the same call.
  def self.revoke_all_for!(user)
    where(user_id: user.id, revoked_at: nil).update_all(revoked_at: Time.current)
  end

  # Revokes the live device tokens of the user that were unused longest, until
  # one more fits under MAX_APP_SESSIONS. Never a personal token: its owner made
  # it on purpose and set its expiry. A device never used counts from the day it
  # was made. Locks the user's row first, so two sign-ins at once count the same
  # devices one after the other; call it inside the transaction that creates the
  # new token.
  #
  # @return [Array<PersonalAccessToken>] the tokens revoked
  def self.make_room_for_app_session!(user)
    transaction do
      User.where(id: user.id).lock.pick(:id)
      live = active.app_sessions.where(user_id: user.id)
                   .order(Arel.sql('COALESCE(last_used_at, created_at) ASC, created_at ASC, id ASC')).to_a
      surplus = live.first([live.size - MAX_APP_SESSIONS + 1, 0].max)
      surplus.each(&:revoke!)
    end
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def app_session?
    kind == APP_SESSION
  end

  # The moment a device token ends whatever its use. nil for a personal token,
  # which ends at expires_at and nowhere else.
  def ends_at
    return nil unless app_session?

    (created_at || Time.current) + APP_SESSION_MAX_AGE
  end

  # Notes a use of the token. For a device token the same statement moves
  # expires_at: MAX_LIFETIME from now, at most #ends_at. update_columns on
  # purpose: no callbacks and no validation, the caller throttles it
  # (Api::TokenAuthenticatable).
  def record_use!(now = Time.current)
    changes = { last_used_at: now }
    changes[:expires_at] = [now + MAX_LIFETIME, ends_at].min if app_session?
    update_columns(changes)
  end

  def active?
    revoked_at.nil? && expires_at.present? && expires_at > Time.current
  end

  def revoked?
    revoked_at.present?
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  # The token's reach as a value object (organisations + per-organisation
  # projects) for token-wide reads. Memoised per instance: scope links do not
  # change within a request.
  def reach
    @reach ||= Reach.from_token(self)
  end

  # One organisation the token reaches right now. all_projects false means only
  # the projects linked in personal_access_token_projects.
  OrganisationScope = Data.define(:organisation_id, :all_projects) do
    def all_projects? = all_projects
  end

  # THE answer to "which organisations does this token reach": the ONE place
  # every door asks (#accessible_organisation?, #accessible_project?, Reach and,
  # through it, /time_sessions/open; the API's /organisations, /projects, /me). Until
  # 2026-10-02 four doors read the link rows themselves, two of them without the
  # active-membership rule, and a token with all_organisations has no link rows.
  #
  # Only organisations where the owner is an ACTIVE member count: a token keeps
  # its links when the membership is deactivated, and must stop reaching that
  # organisation all the same. With all_organisations it is every such
  # organisation at the time of the request, with all its projects, so one
  # joined after the token was made counts at once. Not memoised: the gate asks
  # this before it sets a tenant, and a membership can change between two asks.
  #
  # Tenant-free: Membership and the two link tables are not tenant-scoped, so
  # this works before any tenant is set (it decides whether one may be set).
  #
  # @return [Array<OrganisationScope>]
  def organisation_scopes
    active_org_ids = Membership.active.where(user_id: user_id).select(:organisation_id)
    if all_organisations?
      return active_org_ids.distinct.pluck(:organisation_id)
                           .map { |id| OrganisationScope.new(organisation_id: id, all_projects: true) }
    end

    personal_access_token_organisations.where(organisation_id: active_org_ids).map do |link|
      OrganisationScope.new(organisation_id: link.organisation_id, all_projects: link.all_projects?)
    end
  end

  # The scope for one organisation, or nil when the token does not reach it.
  # The same rule as #organisation_scopes, asked for one organisation only: the
  # gate calls this on every request and needs one row, not the whole list.
  def organisation_scope_for(organisation_id)
    return nil if organisation_id.blank?

    active = Membership.active.where(user_id: user_id, organisation_id: organisation_id)
    if all_organisations?
      return active.exists? ? OrganisationScope.new(organisation_id: organisation_id, all_projects: true) : nil
    end

    link = personal_access_token_organisations.where(organisation_id: active.select(:organisation_id)).first
    link && OrganisationScope.new(organisation_id: link.organisation_id, all_projects: link.all_projects?)
  end

  # Whether this token names the organisation (a link, or with all_organisations
  # every organisation of its owner) while the owner's membership there is
  # deactivated. Such an organisation is outside the reach (#organisation_scopes
  # counts ACTIVE memberships only) and stays so: this opens nothing. It only lets
  # a door refuse it as the missing right of an inactive member instead of
  # answering "not found", for an organisation the holder knows anyway (K4c, the
  # glossary's 403). A removed membership is no inactive membership: false.
  # Tenant-free, like #organisation_scope_for.
  def deactivated_member_of?(organisation_id)
    return false if organisation_id.blank?

    inactive = Membership.inactive.where(user_id: user_id, organisation_id: organisation_id)
    return inactive.exists? if all_organisations?

    personal_access_token_organisations.where(organisation_id: inactive.select(:organisation_id)).exists?
  end

  # The project ids linked to this token within one organisation (the
  # selected-projects mode). Tenant-free, like #organisation_scopes.
  def linked_project_ids(organisation_id)
    ActsAsTenant.without_tenant do
      personal_access_token_projects.joins(:project)
                                    .where(projects: { organisation_id: organisation_id })
                                    .pluck(:project_id)
    end
  end

  # Checks whether the token has access to a specific organisation.
  def accessible_organisation?(organisation)
    return false if organisation.blank?

    organisation_scope_for(organisation.id).present?
  end

  # Checks whether the token has access to a specific project.
  # all_projects=true in the org scope → all of the org's projects are accessible.
  # all_projects=false → only explicitly linked projects.
  #
  # IMPORTANT: uses the join table directly (not via :scoped_projects), so that
  # the check works without a set ActsAsTenant — it is in fact being
  # used to *decide* whether the tenant may be set.
  def accessible_project?(project)
    return false if project.blank?

    scope = organisation_scope_for(project.organisation_id)
    return false unless scope
    return true if scope.all_projects?

    personal_access_token_projects.exists?(project_id: project.id)
  end

  private

  def expires_within_max_lifetime
    return if expires_at.blank? || expires_at <= MAX_LIFETIME.from_now

    errors.add(:expires_at, :beyond_max_lifetime, days: MAX_LIFETIME.in_days.to_i)
  end

  # A device token that could only read could not send, and one limited to some
  # organisations would need somebody to keep that list.
  def app_session_reaches_the_account_and_writes
    return unless app_session?
    return if all_organisations? && !read_only?

    errors.add(:base, :app_session_shape)
  end

  def must_have_at_least_one_organisation_scope
    return if all_organisations?
    return if live_link_records.any?

    errors.add(:base, :no_organisation_scope)
  end

  # One meaning per token: either every organisation, or the linked ones.
  def no_organisation_links_with_all_organisations
    return unless all_organisations?
    return if live_link_records.none? && personal_access_token_projects.none? { |l| !l.marked_for_destruction? }

    errors.add(:base, :organisation_links_with_all_organisations)
  end

  def live_link_records
    personal_access_token_organisations.reject(&:marked_for_destruction?)
  end

  def scoped_projects_must_belong_to_scoped_organisations
    scoped_org_ids = personal_access_token_organisations
                     .reject(&:marked_for_destruction?)
                     .map(&:organisation_id)
    return if scoped_org_ids.empty?

    personal_access_token_projects.each do |link|
      next if link.marked_for_destruction?
      next if link.project.nil?
      next if scoped_org_ids.include?(link.project.organisation_id)

      errors.add(:base, :project_outside_scoped_organisations)
      break
    end
  end
end
