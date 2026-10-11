# frozen_string_literal: true

# =============================================================================
# Admin::Organisation Model - Administrative organisation operations
# =============================================================================
#
# PURPOSE:
# Special version of the Organisation model for admin-backend operations.
# Uses the same table as the regular Organisation model, but without
# acts_as_tenant restrictions, for an administrative overview across all tenants.
#
# MAIN DIFFERENCES FROM THE FRONTEND MODEL:
# ❌ NO acts_as_tenant - enables cross-organisation queries
# ✅ Admin-specific statistics methods
# ✅ All organisations can be managed at the same time
# ✅ Performance-optimized queries for the admin dashboard
#
# DRAWBACKS OF THIS ARCHITECTURE:
# ⚠️  Must be kept in sync with the regular Organisation model
# ⚠️  Additional model class for the same table
# ⚠️  Risk of diverging validations/callbacks
# ⚠️  Complicates refactoring because two models are affected
#
# IMPORTANT:
# - This model may ONLY be used in the admin area!
# - For all frontend operations, the regular Organisation model MUST be used
# =============================================================================

# == Schema Information
#
# Table name: organisations
#
#  id                        :uuid             not null, primary key
#  ai_access_token           :text
#  ai_activated_at           :datetime
#  ai_api_base               :string
#  ai_connection_checked_at  :datetime
#  ai_connection_status      :string
#  ai_enabled                :boolean          default(FALSE), not null
#  ai_package_selected_at    :datetime
#  ai_package_tier_key       :string
#  ai_provider               :string           default("openai")
#  ai_quota_buffer_override  :integer
#  ai_quota_credits_override :integer
#  data_import_enabled       :boolean          default(FALSE), not null
#  domain                    :string
#  email_subject_prefix      :string
#  embedding_access_token    :text
#  embedding_api_base        :string
#  embedding_dims            :integer
#  embedding_model           :string
#  embedding_provider        :string
#  embedding_retention_limit :integer          default(2), not null
#  name                      :string
#  notification_sender_email :string
#  preferred_chat_model      :string
#  project_chat_enabled      :boolean          default(FALSE), not null
#  subdomain                 :string
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  account_id                :uuid
#  active_embedding_space_id :uuid
#  ai_activated_by_id        :uuid
#  ai_organization_id        :string
#  ai_package_id             :uuid
#  ai_package_selected_by_id :uuid
#  embedding_organization_id :string
#
# Indexes
#
#  index_organisations_on_account_id                 (account_id)
#  index_organisations_on_ai_activated_by_id         (ai_activated_by_id)
#  index_organisations_on_ai_package_id              (ai_package_id)
#  index_organisations_on_ai_provider                (ai_provider)
#  index_organisations_on_notification_sender_email  (notification_sender_email)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (active_embedding_space_id => embedding_spaces.id) ON DELETE => nullify
#  fk_rails_...  (ai_activated_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (ai_package_id => ai_packages.id)
#  fk_rails_...  (ai_package_selected_by_id => users.id) ON DELETE => nullify
#
module Admin
  class Organisation < ApplicationRecord
    # Uses the same table as the regular Organisation model
    self.table_name = 'organisations'

    # Encrypt AI credentials — the SAME column set as the runtime Organisation
    # model (both classes write the same table). A shadow model missing one of
    # these declarations would write that column as CLEARTEXT while the runtime
    # model expects ciphertext; the symmetry example in
    # spec/models/token_reencryptable_guard_spec.rb fails on any drift.
    encrypts :ai_access_token, deterministic: false
    encrypts :embedding_access_token, deterministic: false

    # Route configuration for the admin namespace
    def self.model_name
      ActiveModel::Name.new(self, nil, 'Organisation')
    end

    # NO acts_as_tenant - enables admin access across all tenants

    # Validations (same as regular Organisation model)
    validates :name, presence: true, uniqueness: true
    # Embedding-dims gate mirrored from the regular Organisation model (see there
    # for the §3.2 rationale and what changing it costs operationally) — deliberate
    # duplication per this file's header contract, keep both in sync. Without the
    # mirror an admin-side write could persist a dim the Factory then trusts blindly.
    # The i18n key resolves because self.model_name is overridden to
    # 'Organisation' above.
    validates :embedding_dims, inclusion: {
      in: ::Organisation::SUPPORTED_DIMS,
      message: :supported_dimension
    }, allow_nil: true
    # Retention-limit gate, mirrored for the same reason as embedding_dims above
    # (embedding v2 PR 6a) — and it matters MORE here: the admin area is where the
    # switch flow lives (sheet §5.3), so this is the model an operator actually writes
    # the value through. NOT allow_nil: the column is NOT NULL with default 2.
    validates :embedding_retention_limit, inclusion: {
      in: ::Organisation::RETENTION_LIMIT_RANGE,
      message: :supported_retention_limit
    }

    # Associations (without tenant restrictions)
    has_many :memberships, class_name: 'Admin::Membership', dependent: :destroy
    has_many :users, through: :memberships, class_name: 'Admin::User'
    has_many :projects, class_name: 'Admin::Project', dependent: :destroy
    has_many :roles, class_name: 'Admin::Role', dependent: :destroy
    has_many :ai_usages, class_name: 'Admin::AiUsage', dependent: :destroy
    # Account is tenant-independent by design (no acts_as_tenant), so no Admin::
    # shadow variant is needed here -- the plain top-level Account is safe to
    # reference directly.
    belongs_to :account, optional: true
    # Same reasoning for the KI-Paket (ai_packages carries no acts_as_tenant).
    # NOT optional decoration: Lalabase::Llm::Factory asks every routing question
    # through `organisation.try(:ai_package)` (#curated_package), so WITHOUT this
    # association every admin-side org answers "no package" -- i.e. a curated org
    # would be presented as custom, naming a credential it never routes through.
    belongs_to :ai_package, optional: true

    # This admin-backend org-creation path (Actors::CreateUserWithOrganisation,
    # used by Admin::UsersController#create) bypasses the regular Organisation
    # model entirely -- its callbacks never fire here. Including the SAME
    # concern (rather than duplicating the callback) keeps both models'
    # auto-account behaviour identical by construction; see
    # AccountAutoAssignable for the full rationale (D8) and why owner stays
    # nil on this path (this controller's actor is a Beuser, s.
    # app/services/actors/create_user_with_organisation.rb).
    include AccountAutoAssignable

    # The operator switch behind the admin toggle. Shared with ::Organisation rather
    # than duplicated: the twin-parity guard exists because that went wrong three times.
    # ⚠️ Release 2 of the code-index rename (doc/projekt_chat_abbau_plan.md step 4).
    # `project_chat_enabled` is dropped in release 3, and a model that still SELECTs a
    # dropped column answers 500 on every read -- so it stops being selected HERE, one
    # release earlier. Declared on both twins because both write this table.
    self.ignored_columns += %w[project_chat_enabled]

    include CodeIndexingGated

    # T17, same mirroring rationale as the line above: this class has its OWN
    # `has_many :ai_usages, dependent: :destroy`, so a flush declared only on
    # Organisation would miss every deletion performed through the admin path.
    include AiUsageRollupFlushable

    # Scopes for admin filtering
    scope :ordered_by_name, -> { order(:name) }
    scope :ordered_by_creation, -> { order(:created_at) }
    scope :with_domain, -> { where.not(domain: [nil, '']) }
    scope :with_subdomain, -> { where.not(subdomain: [nil, '']) }

    # Admin-specific helper methods
    def display_name
      name.presence || "Organisation #{id&.slice(0, 8)}"
    end

    def domain_info
      parts = []
      parts << "Domain: #{domain}" if domain.present?
      parts << "Subdomain: #{subdomain}" if subdomain.present?
      parts.join(' | ')
    end

    def full_url
      return domain if domain.present?
      return "#{subdomain}.example.com" if subdomain.present?

      nil
    end

    # Statistics methods for the admin dashboard
    def total_users_count
      memberships.distinct.count(:user_id)
    end

    def active_users_count
      memberships.where(active: true).distinct.count(:user_id)
    end

    def inactive_users_count
      memberships.where(active: false).distinct.count(:user_id)
    end

    def total_projects_count
      projects.count
    end

    def admin_users_count
      memberships.joins(:role).where('roles.title' => ::Role::ACCOUNT_ADMIN_TITLE).count
    end

    # Membership helper methods
    def membership_for_user(user_id)
      memberships.find_by(user_id: user_id)
    end

    def has_active_user?(user_id)
      memberships.where(user_id: user_id, active: true).exists?
    end

    # Loading memberships with preloaded associations for admin views
    def memberships_with_details
      memberships.includes(:user, :role).joins(:user).order('users.email')
    end

    # AI configuration (if relevant for the admin view)
    def ai_provider_info
      return 'Kein AI Provider' if ai_provider.blank?

      "#{ai_provider.capitalize}#{ai_organization_id.present? ? " (#{ai_organization_id})" : ''}"
    end

    def ai_configured?
      ai_access_token.present? && ai_provider.present?
    end

    # AI credentials check for the admin dashboard. Mirrors the regular
    # Organisation model INCLUDING its provider argument (deliberate duplication
    # per this file's header contract): Lalabase::Llm::Factory asks this question
    # provider-aware (#organisation_has_own?), so the arity-less variant raised
    # ArgumentError the moment an admin surface routed through the factory — and
    # answered a different question in the meantime. A token saved for anthropic
    # is not "own credentials" for an org whose provider column reads openai; the
    # factory walks past it to the system credential, and so must this predicate.
    def has_own_ai_credentials?(provider = ::AiCredential::PROVIDER_OPENAI)
      ai_access_token.present? && (ai_provider.blank? || ai_provider == provider)
    end

    # Get human-readable name for the organisation's AI provider
    # Delegates to AiCredential — the single display-name source (S1); mirrors
    # Organisation#ai_provider_display_name so admin and app can never diverge.
    def ai_provider_display_name
      ::AiCredential.provider_display_names[ai_provider] || ai_provider&.capitalize || 'Standard'
    end

    # Get masked version of organisation's AI token for display purposes
    # Mirrors the method from the regular Organisation model
    def masked_ai_token
      return nil unless ai_access_token.present?

      case ai_provider || ::AiCredential::PROVIDER_OPENAI
      when ::AiCredential::PROVIDER_OPENAI
        'sk-' + '*' * 40 + ai_access_token.last(8)
      when ::AiCredential::PROVIDER_ANTHROPIC
        'sk-ant-' + '*' * 80 + ai_access_token.last(8)
      else
        '*' * 40 + ai_access_token.last(8)
      end
    end

    # AI usage statistics
    def total_ai_usage_tokens
      ai_usages.sum(:tokens_used)
    end

    def total_ai_usage_cost_cents
      ai_usages.sum(:cost_cents)
    end

    def recent_ai_usage_tokens(days = 30)
      ai_usages.recent(days).sum(:tokens_used)
    end

    def recent_ai_usage_cost_cents(days = 30)
      ai_usages.recent(days).sum(:cost_cents)
    end

    # ==========================================================================
    # Admin role management (CRITICAL DUPLICATION)
    # ==========================================================================

    # Find or create the account-admin role (for the admin backend)
    # Uses find_or_create_by! for atomicity (race-condition-safe via DB unique index)
    def find_or_create_account_admin_role
      roles.find_or_create_by!(title: ::Role::ACCOUNT_ADMIN_TITLE) do |role|
        role.description = 'Administrator mit vollen Zugriffsrechten'
        role.is_default = false
      end
    end
  end
end
