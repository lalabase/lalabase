# frozen_string_literal: true

# == Schema Information
#
# Table name: users
#
#  id                      :uuid             not null, primary key
#  active                  :boolean          default(TRUE), not null
#  changelog_last_read_at  :datetime
#  confirmation_sent_at    :datetime
#  confirmation_token      :string
#  confirmed_at            :datetime
#  deleted_at              :datetime
#  deletion_canceled_at    :datetime
#  deletion_reason         :text
#  deletion_recommended    :boolean          default(FALSE), not null
#  email                   :string           default(""), not null
#  encrypted_password      :string           default(""), not null
#  failed_attempts         :integer          default(0), not null
#  first_name              :string
#  is_ai                   :boolean          default(FALSE)
#  language_preference     :string           default("de"), not null
#  last_name               :string
#  last_seen_at            :datetime
#  locked_at               :datetime
#  preferences             :jsonb            not null
#  remember_created_at     :datetime
#  reset_password_sent_at  :datetime
#  reset_password_token    :string
#  scheduled_deletion_at   :datetime
#  session_timeout_minutes :integer          default(30), not null
#  terms_accepted_at       :datetime
#  timezone                :string           default("Europe/Berlin")
#  unconfirmed_email       :string
#  unlock_token            :string
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  invited_by_org_id       :uuid
#  invited_by_user_id      :uuid
#
# Indexes
#
#  index_users_on_confirmation_token     (confirmation_token) UNIQUE
#  index_users_on_deleted_at             (deleted_at)
#  index_users_on_deletion_recommended   (deletion_recommended)
#  index_users_on_email_active           (email) UNIQUE WHERE (deleted_at IS NULL)
#  index_users_on_invited_by_org_id      (invited_by_org_id)
#  index_users_on_invited_by_user_id     (invited_by_user_id)
#  index_users_on_language_preference    (language_preference)
#  index_users_on_last_seen_at           (last_seen_at)
#  index_users_on_preferences            (preferences) USING gin
#  index_users_on_scheduled_deletion_at  (scheduled_deletion_at)
#  index_users_on_timezone               (timezone)
#  index_users_on_unlock_token           (unlock_token) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (invited_by_org_id => organisations.id)
#  fk_rails_...  (invited_by_user_id => users.id)
#

class User < ApplicationRecord
  include SoftDeletable
  include UserTrackable
  # Presence "last seen" heartbeat (mark_seen! / online?) — see User::Presence.
  include User::Presence
  # Account-deletion / GDPR lifecycle (user split, slice 5) — methods stay
  # instance methods on User, see User::DeletionLifecycle.
  include User::DeletionLifecycle

  # Organisation membership + authorization surface (user split, slice 7) — both
  # are behaviour concerns mixed back into User, so the methods stay instance
  # methods on User and every call site (incl. the 18 Pundit policies and the two
  # request-level caches @role_cache / @active_member_cache) keeps working
  # unchanged. Method resolution happens at call time, so the include order here
  # is irrelevant. See User::OrganisationMembership / User::Authorization.
  include User::OrganisationMembership
  include User::Authorization

  # Name rendering (full_name / display_name(mode:) / initials) — the single
  # owner for every render site, see User::NameDisplay. Plain instance
  # methods, no Devise interplay, so the include position is not load-bearing.
  include User::NameDisplay

  # Which email the others see (login address, contact address or none) --
  # the single owner, see User::EmailDisplay.
  include User::EmailDisplay

  # Allowed per-user session-timeout values (minutes). DELIBERATELY defined on
  # the User class, NOT inside User::Authenticatable: it is referenced externally
  # as User::ALLOWED_SESSION_TIMEOUTS (app/views/user_preferences/session.html.erb).
  # User::Authenticatable's session_timeout_minutes validation resolves the
  # bareword to this constant via lexical nesting, so it must be defined BEFORE
  # that concern is included.
  ALLOWED_SESSION_TIMEOUTS = [30, 120, 480, 1440].freeze

  # Language preference is i18n / profile, not authentication, so it stays on
  # User; User::Authenticatable is scoped to Devise + email/password/session.
  validates :language_preference, inclusion: { in: %w[de en] }

  # The zone this person's calendar runs in (users.timezone, default
  # Europe/Berlin), the app zone (UTC) when the stored name is unknown. A time
  # booking is DATED in it: a call at 00:30 Berlin belongs to that Berlin day,
  # not to the UTC day before (Lalabase::Tools::CreateTimeSession).
  def time_zone
    ActiveSupport::TimeZone[timezone.to_s] || Time.zone
  end

  # Authentication surface (user split, slice 6): Devise registration, the
  # custom email/password validations and the session-timeout inclusion
  # validation. Behaviour stays on User — see User::Authenticatable.
  include User::Authenticatable

  # Devise delivers its own mails INSIDE the request, and the confirmation mail
  # goes out from an after_commit on create. A mail server that refuses the
  # login therefore turned a signup that had already committed into a 500: the
  # account existed, the customer saw an error, and their second attempt met
  # "email already taken". Measured on staging through the provisioning
  # endpoint, where it first became visible -- the form here has the same hole.
  #
  # Queued instead, like every other mail this app sends (Signups::FollowUps
  # does the same for the founder request). ActiveJob carries I18n.locale into
  # the job, so the mail still renders in the language of the signup. What is
  # given up: an undeliverable mail now fails in the worker and its log rather
  # than in the request, which is the right place for it -- nobody fixes a mail
  # server by resubmitting a form.
  #
  # ⚠️ Defined HERE and not in User::Authenticatable, for the same reason
  # timeout_in is (see the note there): `devise :database_authenticatable`
  # runs inside that concern's `included do`, so Devise's own modules land
  # ABOVE it in the ancestor chain and shadow any override it makes. Measured:
  # in the concern, user.method(:send_devise_notification).owner was still
  # Devise::Models::Authenticatable and nothing changed.
  def send_devise_notification(notification, *args)
    devise_mailer.send(notification, self, *args).deliver_later
  end

  # System account "Lalabase" (onboarding seed actor): reserved email plus
  # authentication + deletion fence. Must sit BELOW Authenticatable so its
  # active_for_authentication? override wraps the Devise implementation.
  include User::SystemAccount

  # timeout_in DELIBERATELY stays on the User class, NOT in User::Authenticatable.
  # `devise :timeoutable` mixes Devise::Models::Timeoutable (whose own timeout_in
  # returns the global config.timeout_in) into User from inside the concern's
  # `included do`, so that module lands ABOVE the concern in the ancestor chain
  # and would shadow a concern-level override (verified: it sits at ancestor
  # index 1, the concern far below). A method defined directly on the class is
  # first in the MRO and reliably wins — that is what makes the per-user session
  # timeout actually take effect instead of falling back to the 30-minute global.
  def timeout_in
    session_timeout_minutes.minutes
  end

  # The published login of the demo (Lalabase::Demo) is shared by every visitor,
  # so counting failed attempts would let anybody lock it for everybody. Defined
  # here for the same ancestor reason as timeout_in: `devise :lockable` lands
  # above the concerns.
  def lock_strategy_enabled?(strategy)
    super && !Lalabase::Demo.published_login?(email)
  end

  # confirmation_period_valid? lives here for the SAME ancestor reason as
  # timeout_in above: `devise :confirmable` mixes Devise::Models::Confirmable
  # into User from inside User::Authenticatable's `included do`, so it lands
  # ABOVE that concern and would shadow an override defined there.
  #
  # WHY override at all: Devise measures the grace period from
  # confirmation_sent_at, and the public resend endpoint RESETS that field once
  # confirm_within has elapsed (Confirmable#generate_confirmation_token,
  # devise-4.9.4:248 — expired token → new token AND
  # `confirmation_sent_at = now`). A never-confirmed account could therefore
  # POST /users/confirmation every seven days and renew its three days of full
  # access forever, without ever proving the address — which is the single
  # property this whole feature exists to provide. The 3/min throttle does not
  # help against one request per week.
  #
  # Anchoring the window to created_at fixes that: a resend still delivers a
  # fresh link (and must, or an expired token would be a dead end), it just
  # buys no additional access. Mirrors Devise's own guard clauses so a config
  # of nil / 0.days keeps behaving exactly as documented.
  def confirmation_period_valid?
    return true if self.class.allow_unconfirmed_access_for.nil?
    return false if self.class.allow_unconfirmed_access_for == 0.days

    created_at && created_at.utc >= self.class.allow_unconfirmed_access_for.ago
  end

  # Associations
  has_many :memberships, dependent: :destroy
  has_many :organisations, through: :memberships
  has_many :roles, through: :memberships

  # Profile picture (doc/user_display_name_avatar_plan.md, S2). Rules (types,
  # max size, thumb dimensions) have ONE owner: UserAvatar. Rendered only by
  # Neo::Users::NameComponent in 'circle' mode; the :thumb variant is
  # pre-warmed on attach so no request pays the vips run.
  # DELIBERATELY on ::User only, NOT in the shared User::NameDisplay concern:
  # an attachment declared on Admin::User would read/write record_type
  # "Admin::User" and never find the blobs attached here (polymorphic type is
  # the base class, unaffected by the model_name override). The admin backend
  # renders initials only. dependent purge covers a hard DELETE; the soft
  # erasure paths purge explicitly in PersonalDataErasure.
  has_one_attached :avatar do |attachable|
    attachable.variant :thumb, resize_to_fill: UserAvatar::THUMB_SIZE, preprocessed: true
  end
  validate :acceptable_avatar

  # Checkbox seam for the display settings: "1" purges the avatar after save.
  # A virtual attribute instead of controller logic, so a plain
  # current_user.update can carry it like any attribute
  # (UserPreferencesController#apply_avatar_update). It used to ride Devise's
  # update_with_password path; the picture moved out of that form on
  # 04.09.2026 because the gate demanded the current password for a picture.
  attr_accessor :remove_avatar

  after_save :purge_avatar_if_requested

  has_many :posts, dependent: :destroy
  has_many :post_reactions, dependent: :destroy
  has_many :post_reads, dependent: :destroy
  has_many :project_permissions, dependent: :destroy
  has_many :permitted_projects, through: :project_permissions, source: :project
  has_many :time_session_permissions, dependent: :destroy

  # Assignments
  has_many :ticket_assignments, dependent: :destroy
  has_many :assigned_tickets, through: :ticket_assignments, source: :ticket

  # Invite tracking associations
  belongs_to :invited_by_user, class_name: 'User', optional: true
  belongs_to :invited_by_org, class_name: 'Organisation', optional: true

  # Invitations made by this user
  has_many :invited_users, class_name: 'User', foreign_key: 'invited_by_user_id', dependent: :nullify

  # Index runs that this user triggered. nullify (matching the FK
  # on_delete: :nullify), so that the run history survives a deleted trigger
  # instead of blocking the delete or dragging the history down with it.
  has_many :triggered_index_runs, class_name: 'ProjectIndexRun',
                                  foreign_key: 'triggered_by_user_id', dependent: :nullify

  # Notification system associations
  has_many :notifications, foreign_key: 'recipient_id', dependent: :destroy
  has_many :created_notifications, class_name: 'Notification', foreign_key: 'actor_id', dependent: :nullify
  has_many :notification_preferences, dependent: :destroy
  has_many :notification_subscriptions, dependent: :destroy
  has_many :personal_access_tokens, dependent: :destroy
  # GDPR self-service exports (Art. 15/20). dependent: :destroy covers a hard
  # DELETE only — the real erasure paths (soft-delete, self-service AND admin)
  # purge these explicitly in PersonalDataErasure, because soft-deletes never
  # fire dependent callbacks.
  has_many :user_data_exports, dependent: :destroy
  # Persistent chat answer-style levels (ChatStylePreference, v1.5).
  # Deliberately NO `dependent:` option: cleanup on a hard user delete is handled
  # by the DB-level ON DELETE CASCADE on chat_style_preferences.user_id (see the
  # migration). A Rails `dependent: :destroy` would be WRONG here — ChatStylePreference
  # is acts_as_tenant, so the association runs through its tenant default scope and
  # would only delete the CURRENT tenant's rows; a hard destroy of a multi-org user
  # with a tenant set then raises InvalidForeignKey on the other orgs' rows. The DB
  # cascade is tenant-independent. (Normal soft-deletes never call #destroy, so a
  # soft-deleted user keeps their style — only a real hard delete/GDPR purge cascades.)
  has_many :chat_style_preferences

  # ==========================================================================
  # Multi-tenancy Configuration
  # ==========================================================================
  # Note: acts_as_tenant is NOT used on User model because users can belong
  # to multiple organizations. Tenant isolation is handled through the
  # Membership join model instead.
  # acts_as_tenant(:organisation) # REMOVED - see above

  # ==========================================================================
  # User Status Scopes
  # ==========================================================================
  # These scopes provide easy filtering of users based on their active status.
  # Used extensively in admin interfaces and reporting.
  #
  # Examples:
  #   User.active     # Returns all users where active = true
  #   User.inactive   # Returns all users where active = false
  #   User.active.count # Count of active users
  # ==========================================================================
  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }

  # ==========================================================================
  # Notification Methods
  # ==========================================================================

  def unread_notifications_count(organisation = nil)
    return notifications.channel_in_app.unread.count unless organisation

    Notification.inbox_unread(self, organisation).count
  end

  # === Preferences (user split, slice 1) ===
  # The user preferences (JSONB column preferences) live in
  # User::PreferenceStore; the update form goes through User::PreferencesForm.
  # Memoized on the user instance => same lifetime as the other per-instance
  # caches (@role_cache etc.), no extra caching layer.
  def preference_store
    @preference_store ||= User::PreferenceStore.new(self)
  end

  # Facade for high fan-in consumers (Pageable, ApplicationHelper, views):
  # these methods stay permanently callable directly on the user.
  delegate :items_per_page_preference, :date_strftime_format, :overview_widget_period, to: :preference_store

  # === Sidebar pins (user split, slice 2) ===
  # Pinned projects/menu sections per organisation live in User::SidebarPins;
  # call sites use user.sidebar_pins directly (no delegation facade).
  def sidebar_pins
    @sidebar_pins ||= User::SidebarPins.new(self)
  end

  # === Org recognition color (user split, slice 3) ===
  # Per-user, per-org recognition color lives in User::OrgColorSettings;
  # call sites use user.org_colors directly (no delegation facade).
  # The memo matters for more than lifetime consistency here: the PORO
  # memoizes the active-org COUNT internally, so a fresh instance per call
  # would re-fire one COUNT query per rendered org (silent N+1 — guarded by
  # the query-count spec in spec/models/user/org_color_settings_spec.rb).
  def org_colors
    @org_colors ||= User::OrgColorSettings.new(self)
  end

  # === Ticket notification settings (user split, slice 4) ===
  # The ticket notification toggles (preferences['ticket_notifications'])
  # live in User::NotificationSettings.
  def notification_settings
    @notification_settings ||= User::NotificationSettings.new(self)
  end

  # Deliberate delegation facade (NOT a forgotten call-site migration): both
  # methods run in the notification delivery hot path —
  # ticket_notification_enabled_for? in Notifications::FanoutService inside
  # Solid Queue jobs, ticket_auto_follow_created? across 7 call sites
  # including an after_create_commit callback (Ticket#auto_subscribe_creator).
  # Failures there surface asynchronously in jobs, not in request specs, and
  # existing specs stub these methods on the user — the facade keeps all of
  # those contracts stable.
  delegate :ticket_notification_enabled_for?, :ticket_auto_follow_created?,
           to: :notification_settings

  private

  # The JSONB-preference gates live in the controller; the avatar is a real
  # attachment, so its rules are model validations. Runs against the pending
  # blob before anything is persisted — a rejected file never sticks, and the
  # orphaned blob is swept by UnattachedBlobPurgeJob.
  def acceptable_avatar
    return unless avatar.attached? && avatar.blob

    errors.add(:avatar, :invalid_content_type) unless UserAvatar::CONTENT_TYPES.include?(avatar.blob.content_type)
    return unless avatar.blob.byte_size > UserAvatar::MAX_BYTE_SIZE

    errors.add(:avatar, :too_large, max_megabytes: UserAvatar.max_megabytes)
  end

  # A picture picked in the SAME submit wins over a checkbox left ticked from
  # the previous state: has_one_attached registers its own after_save first, so
  # by the time this runs the new file is already attached and purging it would
  # answer "replace my picture" with a success flash and no picture at all.
  def purge_avatar_if_requested
    return if attachment_changes.key?('avatar')
    return unless ActiveModel::Type::Boolean.new.cast(remove_avatar) && avatar.attached?

    avatar.purge_later
  end
end
