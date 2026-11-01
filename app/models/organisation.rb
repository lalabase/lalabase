# frozen_string_literal: true

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
#  meeting_inbox_project_id  :uuid
#
# Indexes
#
#  index_organisations_on_account_id                 (account_id)
#  index_organisations_on_ai_activated_by_id         (ai_activated_by_id)
#  index_organisations_on_ai_package_id              (ai_package_id)
#  index_organisations_on_ai_provider                (ai_provider)
#  index_organisations_on_meeting_inbox_project_id   (meeting_inbox_project_id)
#  index_organisations_on_notification_sender_email  (notification_sender_email)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (active_embedding_space_id => embedding_spaces.id) ON DELETE => nullify
#  fk_rails_...  (ai_activated_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (ai_package_id => ai_packages.id)
#  fk_rails_...  (ai_package_selected_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (meeting_inbox_project_id => projects.id) ON DELETE => nullify
#

class Organisation < ApplicationRecord
  # Billing bundling level (plan doc/billing_agentur_konto_plan.md D2/D3).
  # optional: true, because account_id is still nullable (backfill via T4/T3
  # runs outside this migration) -- becomes NOT NULL in a later migration
  # after the backfill.
  belongs_to :account, optional: true

  # ================================
  # AI CREDENTIALS SYSTEM
  # ================================
  # This system provides hierarchical AI provider management with three fallback levels:
  # 1. Organisation-specific credentials (stored in this model)
  # 2. System-wide credentials (managed via admin interface)
  # 3. Environment variables (backwards compatibility)
  #
  # Features:
  # - Multi-provider support (OpenAI, Anthropic, Google, Cohere)
  # - Encrypted credential storage
  # - Usage tracking and cost estimation
  # - Automatic failover between credential sources
  # - Client wrapper for transparent usage monitoring
  # ================================

  # Encrypt AI credentials
  encrypts :ai_access_token, deterministic: false
  # Per-org embedding BYOK token (own sovereign / OpenAI-compatible endpoint).
  # Separate from chat: embeddings route off the embedding_* columns, not ai_*.
  encrypts :embedding_access_token, deterministic: false

  # Maintenance rewrite path for the two encrypted columns above (backfill +
  # key rotation): rake encryption:reencrypt_tokens → .reencrypt_tokens!
  # Registered HERE and not on Admin::Organisation: exactly ONE model per table
  # may register (guard: spec/models/token_reencryptable_guard_spec.rb), and
  # the runtime model is the table's owner — the shadow only mirrors the
  # `encrypts` declarations (shadow symmetry, same guard spec).
  include TokenReencryptable
  reencrypts_tokens :ai_access_token, :embedding_access_token

  # Associations
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :invitations, dependent: :destroy
  has_many :roles, dependent: :destroy
  has_many :projects, dependent: :destroy
  # Read it through #meeting_inbox: the column alone does not say whether the
  # project still takes meetings.
  belongs_to :meeting_inbox_project, class_name: 'Project', optional: true, inverse_of: false
  has_many :tickets, through: :projects
  has_many :smart_folders, dependent: :destroy
  # Project#view_configurations takes the rows of a project; this one takes the
  # rows without a project (the base view of "Alle Meetings"). The FK is NO ACTION.
  has_many :view_configurations, dependent: :destroy
  has_many :ai_usages, dependent: :destroy
  has_many :codebase_import_files, dependent: :destroy
  has_many :tags, dependent: :destroy
  # The shared people directory (Person). Rails-driven cleanup like the rows above.
  has_many :people, dependent: :destroy
  has_many :personal_access_token_organisations, dependent: :destroy

  # The one order for lists of organisations a person sees: by name ignoring case, then by id
  # (two organisations may share a name). reorder, so it wins over an order already on the
  # relation. The org switcher, its unread signal, the token inbox overview and the API lists
  # use it, so the terminal shows the order of the app. Spec: organisation_by_name_spec.rb.
  scope :by_name, -> { reorder(Arel.sql('LOWER(organisations.name) ASC'), :id) }

  # Per-org chat personas (PromptPersona, v2 feature). This association matches
  # only rows with organisation_id = this org, so the GLOBAL pool (organisation_id
  # NULL, shared by all orgs) is never touched — it survives an org deletion.
  # dependent: :destroy (not a DB cascade) keeps us consistent with every other
  # org-owned table here; org deletion is Rails-driven, the DB FKs stay NO ACTION.
  # Invariant for v2: per-org personas must stay system: false — a system: true
  # per-org row would trip prevent_system_destroy and block the whole org delete.
  has_many :prompt_personas, dependent: :destroy
  # Per-user chat answer-style levels (ChatStylePreference, v1.5). Rails-driven
  # cleanup on org deletion, matching every other org-owned table — the FK stays
  # NO ACTION (no DB cascade), so removing this line would make an org delete
  # raise InvalidForeignKey rather than silently orphan rows.
  has_many :chat_style_preferences, dependent: :destroy
  # GDPR org-level AI opt-in (audit 2026-07-03): the admin who enabled AI
  # features. Kept as activation history after deactivation; nullified when
  # the user account is deleted (FK on_delete: :nullify).
  belongs_to :ai_activated_by, class_name: 'User', optional: true

  # Every vector space this org holds (embedding v2 PR 6a). dependent: :destroy for
  # consistency with the other org-owned tables; the DB FK additionally cascades, so a
  # callback-free parent delete cannot orphan them either.
  has_many :embedding_spaces, dependent: :destroy
  # The space that SERVES this org's queries — the pointer the staged switch flips
  # (doc/embedding_v2_pr6_retention_plan.md §4.2). Convenience only: the serving
  # resolution in Lalabase::Llm::Factory deliberately does NOT go through this
  # association, because acts_as_tenant's default scope on EmbeddingSpace would make it
  # resolve to nil under a FOREIGN ambient tenant and silently fall back to the
  # configured space — a B1 breakage with a different cause. See
  # Factory#active_space_row.
  belongs_to :active_embedding_space, class_name: 'EmbeddingSpace', optional: true

  # KI-Pakete P2 (plan §6.1, E1-C): the org's curated bundle. NULL behaves like
  # kind 'custom' — the factory resolution branches on the package, never on a
  # second code path, and existing orgs need no data migration.
  # ai_package_selected_at/_by is the switch protocol (§7); the tier is
  # addressed by ai_package_tier_key (fast/thorough — customer switch in P3).
  belongs_to :ai_package, optional: true
  belongs_to :ai_package_selected_by, class_name: 'User', optional: true

  # D8 (see also the Cross-Model Tension note in the plan, D9): fires on
  # every Organisation creation, including factories/rake tasks. Logic +
  # rationale live in the shared concern (also included by Admin::Organisation).
  include AccountAutoAssignable
  # Shared with Admin::Organisation by construction, see the concern's header.
  # ⚠️ Release 2 of the code-index rename (doc/projekt_chat_abbau_plan.md step 4).
  # `project_chat_enabled` is dropped in release 3, and a model that still SELECTs a
  # dropped column answers 500 on every read -- so it stops being selected HERE, one
  # release earlier. Declared on both twins because both write this table.
  self.ignored_columns += %w[project_chat_enabled]

  include CodeIndexingGated

  # T17: rescues this org's AI consumption onto its Account before
  # `has_many :ai_usages, dependent: :destroy` (above) takes it. Also included
  # by Admin::Organisation -- separate callback cycles, same table.
  include AiUsageRollupFlushable

  # The configurable embedding dimensions (doc/embedding_v2_multidim_plan.md §3.5):
  # 768 (nomic), 1024 (mistral-embed/bge-m3), 1536 (OpenAI-small/today) and, since
  # PR 5b, 3072 (text-embedding-3-large, gemini-embedding-001).
  #
  # Each has its own expression-partial HNSW index on the sidecar (migrations
  # 20260719160000 + 20260731120000 + 20260801120000). The first three fit pgvector's
  # 2000-dim ANN-index limit and are indexed as plain `vector`; 3072 exceeds it and is
  # indexed via a `halfvec` CAST instead (stored at full precision, fp16 only inside
  # the index). Which cast belongs to which dim is NOT decided here — that is
  # Embeddings::NearestNeighbors::INDEX_CAST_TYPE, because the query has to spell the
  # very same cast or the planner silently skips the index.
  #
  # 3072 additionally requires pgvector >= 0.7.0 (halfvec). Below that the index
  # cannot be created at all; the boot check in config/initializers/pgvector_halfvec.rb
  # warns when an org is on 3072 anyway.
  #
  # The ONE source: the org validation, the Admin:: mirror and the credential-JSON
  # clamp in Lalabase::Llm::Factory all read this list.
  SUPPORTED_DIMS = [768, 1024, 1536, 3072].freeze

  # Allowed values for embedding_retention_limit (embedding v2 PR 6, series plan
  # fork §11.4). Lower bound 1 = "keep only the active space"; upper bound 5 caps how
  # much cold vector storage a single org can pin (~6 KB per row per space).
  # The ONE source: the org validation and the Admin:: mirror both read this.
  RETENTION_LIMIT_RANGE = (1..5)

  # Validations
  validates :name, presence: true, uniqueness: true
  validate :meeting_inbox_project_usable, if: :meeting_inbox_project_id_changed?
  # S1 honest facade: the org chat provider must be one the Factory can actually
  # build. Lazy `in:` (evaluated per validation) reads AiCredential.implemented_providers
  # so this allow-list can never drift from the Factory registry. Conditional
  # (only when ai_provider is set/changed) so an org carrying a legacy value —
  # e.g. 'google' before the GoogleVertexProvider slice, or the removed 'cohere' —
  # is not invalidated on unrelated saves (mirrors AiCredentialProviderRules).
  # ai_provider is written only org-side (Organisations::AiSettingsController),
  # so unlike AiCredential no Admin:: twin needs the rule.
  validates :ai_provider, inclusion: {
    in: ->(_org) { AiCredential.implemented_providers },
    message: :supported_provider
  }, allow_blank: true, if: -> { new_record? || will_save_change_to_ai_provider? }
  # v1 embedding lane (1536 dims): only embedding-capable implemented providers.
  # Lazy `in:` derives from the Factory registry + the provider classes'
  # supports_embeddings? declarations (google joined with the Vertex slice) —
  # no hardcoded twin list that could drift.
  validates :embedding_provider, inclusion: {
    in: ->(_org) { AiCredential.embedding_capable_providers },
    message: :supported_provider
  }, allow_blank: true
  # Only a FULL org BYOK setup (own token) must also carry its own base URL +
  # model — fail at config time, not at the first embed. An org that points at
  # openai_compatible WITHOUT its own token relies on the system AiCredential,
  # which supplies uri_base + default_model — so no org-level requirement there.
  validates :embedding_api_base, :embedding_model, presence: true,
                                                   if: lambda {
                                                     embedding_provider == AiCredential::PROVIDER_OPENAI_COMPATIBLE &&
                                                       embedding_access_token.present?
                                                   }
  # Embedding dimension (doc/embedding_v2_multidim_plan.md §3.2): first-class part
  # of the vector-space triple. Accepts nil (→ system default 1536) or any
  # SUPPORTED_DIMS value; allow_nil keeps an unconfigured org byte-identical to
  # today's behaviour. Mirrored in Admin::Organisation (same table, admin writes
  # bypass this model) — deliberate duplication, keep both in sync.
  #
  # CHANGING this on an existing org is a vector-space switch WITHOUT a net until
  # PR 6: retrieval resolves the new triple immediately and returns 0 hits org-wide
  # until the reindex is through. The procedure is documented in the self-hosting
  # BYOK docs (03-configuration/02-ai-byok) — there is no UI for this on purpose.
  validates :embedding_dims, inclusion: {
    in: SUPPORTED_DIMS,
    message: :supported_dimension
  }, allow_nil: true

  # How many vector spaces this org keeps (embedding v2 PR 6, series plan §6.2 /
  # fork §11.4): the active one plus N−1 retained older ones. A SETTING, not a system
  # constant — an org deliberately evaluating three models should be able to say so
  # without a deploy ([[feedback_configurable_over_hardcoded]]).
  #
  # The GC that reads this ships with PR 6b; the column exists from 6a so
  # `organisations` needs only ONE migration. Its protection rules are policy and live
  # in the GC, not here: the active space and a space under construction are never
  # collected, not even at limit = 1.
  #
  # Mirrored in Admin::Organisation (same table, admin writes bypass this model) —
  # deliberate duplication, keep both in sync.
  validates :embedding_retention_limit, inclusion: {
    in: RETENTION_LIMIT_RANGE,
    message: :supported_retention_limit
  }

  # Added scope
  def active_memberships
    memberships.active
  end

  def active_users
    users.merge(Membership.active)
  end

  # Find or create the default role
  def find_or_create_default_role
    default_role = roles.default_roles.first

    default_role ||= roles.create!(
      title: 'Standard-Benutzer',
      description: 'Standardrolle für neue Benutzer',
      is_default: true
    )

    default_role
  end

  # Find or create the account-admin role
  def find_or_create_account_admin_role
    admin_role = roles.find_by(title: 'account_admin')

    admin_role ||= roles.create!(
      title: 'account_admin',
      description: 'Administrator mit vollen Zugriffsrechten',
      is_default: false
    )

    admin_role
  end

  # ================================
  # AI Credentials & Client Methods
  # ================================

  # NOTE: (S2): Organisation#ai_client / #ai_client_with_usage_tracking were removed.
  # Every LLM call now routes through the SINGLE gated seam Lalabase::Llm::Factory
  # (chat via .for_chat, embeddings via .for_embeddings), and usage is recorded by
  # Lalabase::Llm::UsageTracking. The GDPR opt-in gate + BYOK routing live there, so
  # there is no longer a second client path to keep in sync.

  # Check if organisation has its own AI credentials configured
  #
  # @param provider [String] AI provider to check
  # @return [Boolean] true if organisation has own credentials for this provider
  def has_own_ai_credentials?(provider = AiCredential::PROVIDER_OPENAI)
    ai_access_token.present? && (ai_provider.blank? || ai_provider == provider)
  end

  # Has this organisation actually set up its OWN access, i.e. is there something behind
  # "Eigene Konfiguration" (doc/ki_zugang_umbau_plan.md D7)?
  #
  # ONE owner for a rule that four surfaces need since the rebuild: the "Aktuell" line,
  # the chooser tile's "Aktiv" chip, the custom pane and the hub's access card. It was
  # written inline in the view before there was more than one reader, and four copies of
  # the same expression is precisely the duplicated-enforcement trap CLAUDE.md names.
  #
  # ⚠️ NOT the same question as `ai_package_id.blank?`. A blank package id means "own
  # configuration" (convention E1-C) and says nothing about whether credentials exist —
  # which is why a fresh organisation used to read "Eigene Konfiguration · Gewählt"
  # without anyone ever having chosen anything. The distinction lives here, in the
  # derivation, deliberately without a third column in the schema.
  #
  # @return [Boolean]
  # The project meetings without a project land in, or nil. An archived project
  # takes no meetings, so it counts as not set; the column stays, restoring the
  # project brings the inbox back. Sets its own tenant: Project requires one, and
  # a token request reads this before it has entered the project.
  def meeting_inbox
    project = ActsAsTenant.with_tenant(self) { meeting_inbox_project }
    project unless project.nil? || project.archived?
  end

  def ai_custom_access_configured?
    has_own_ai_credentials?(ai_provider.presence || AiCredential::PROVIDER_OPENAI)
  end

  # Check if organisation has its own embedding credentials configured. Mirrors
  # has_own_ai_credentials? but on the independent embedding_* BYOK columns, so an
  # org can run its own sovereign embedding endpoint without touching chat.
  #
  # @param provider [String] embedding provider to check (openai / openai_compatible)
  # @return [Boolean]
  def has_own_embedding_credentials?(provider = AiCredential::PROVIDER_OPENAI)
    embedding_access_token.present? &&
      (embedding_provider.blank? || embedding_provider == provider)
  end

  # Check if organisation has a usable AI configuration for `provider`.
  #
  # S1c (doc/ki_provider_reichweite_plan.md §2.1b): this used to be a
  # `case provider … else false` — every provider except 'openai' answered a hard
  # false, which meant an org on Mistral or Gemini saw no AI actions at all and
  # got a 403 on a direct POST, no matter how correctly the routing underneath
  # was configured. The question itself ("can this org use provider X?") is
  # provider-neutral: an own BYOK token, or an active system credential. Only the
  # TOKEN-SHAPE check is provider-specific, and it now sits behind a provider
  # branch instead of being the general case.
  #
  # @param provider [String] AI provider to check
  # @param utility [Boolean] judge the package's UTILITY rung instead of the org's
  #   own (KI-Pakete P3). Set only by FeatureRegistry, which knows from the
  #   registry row whether the path it gates is helper work — every other caller
  #   asks about the rung the org itself picked. Without it a utility feature
  #   would be gated on one rung and routed on another.
  # @return [Boolean] true if a usable configuration exists
  def has_valid_ai_configuration?(provider = AiCredential::PROVIDER_OPENAI, utility: false)
    provider = provider.to_s.presence || AiCredential::PROVIDER_OPENAI
    # Honest facade, same rule as the ai_provider validation and
    # AiCredentialProviderRules: a provider the Factory cannot build is never a
    # valid configuration. Keeps a legacy org carrying 'cohere' out of the UI
    # instead of offering it a button that raises at the seam.
    return false unless AiCredential.implemented_providers.include?(provider)

    # KI-Pakete P2 (§6.1): a curated org routes through its package, so the
    # package's rung credential is the ONE credential this answer may be about.
    # Asked FIRST for the same reason BYOK is terminal below — and asked through
    # the Factory rather than re-derived here, so gate and route cannot name
    # different credentials. active_for_provider would answer off the provider's
    # STANDARD credential, which with two openai_compatible rows is a different
    # row entirely (§4.1).
    # #usable_for?(:chat), not `enabled?`: the embedding twin has asked for a matching
    # purpose and a resolvable endpoint all along, and this lane asked neither — so an
    # operator editing a referenced credential to 'embedding', or clearing its
    # api_base, left every org on that package "available" right up to the raise
    # inside the provider. Same three conditions on both lanes, one definition.
    curated = Lalabase::Llm::Factory.curated_chat_credential(self, utility: utility)
    return curated.provider == provider && curated.usable_for?(:chat) if curated

    # BYOK is TERMINAL, not a first attempt — mirrors Factory#resolve_credentials,
    # which takes the org token whenever has_own_ai_credentials? holds and never
    # falls back to the system credential. Answering "available" off a system
    # credential the request will not use is precisely the lie this gate exists to
    # prevent.
    return own_ai_token_usable?(provider) if has_own_ai_credentials?(provider)

    system_ai_credential_usable?(provider)
  end

  # The EMBEDDING twin of has_valid_ai_configuration? — the predicate without which
  # no embedding feature is answerable (doc/ai_feature_registry_plan.md §2.3).
  #
  # Nothing in the chat predicate can answer for this lane: it reads ai_access_token /
  # ai_api_base / preferred_chat_model and the CHAT system credential, while the
  # embedding lane routes off independent columns (embedding_*) and needs a credential
  # whose PURPOSE includes embeddings. Asking the chat question about an embedding
  # surface is exactly the mispairing S1c removed, only mirrored — and
  # meetings/_search_status.html.erb:15-23 says so about itself today.
  #
  # Same three properties as its chat twin, for the same reasons: no network call
  # (a gate must not turn a page render into an API request), BYOK is TERMINAL
  # (mirrors Factory#resolve_embedding_credentials, which never consults the system
  # tier once the org brought its own token), and it never raises — a view gate that
  # raises is worse than one that says no.
  #
  # @param provider [String] embedding provider to check
  # @return [Boolean] true if a usable embedding configuration exists
  def has_valid_embedding_configuration?(provider = AiCredential::PROVIDER_OPENAI)
    provider = provider.to_s.presence || AiCredential::PROVIDER_OPENAI
    # Honest facade, one notch stricter than the chat twin: this lane needs a provider
    # the Factory can build AND that declares supports_embeddings? (AnthropicProvider
    # does not). Derived from the provider classes, never a second hardcoded list.
    return false unless AiCredential.embedding_capable_providers.include?(provider)

    # The package branch, exactly as in the chat twin (§6.1) — and the PURPOSE
    # question travels with it: Factory#resolve_embedding_credentials refuses a
    # chat-only credential on this lane, so a gate that did not ask would offer
    # a feature the seam declines.
    curated = Lalabase::Llm::Factory.curated_embedding_credential(self)
    return curated_embedding_credential_usable?(curated, provider) if curated

    return own_embedding_token_usable?(provider) if has_own_embedding_credentials?(provider)

    system_embedding_credential_usable?(provider)
  end

  # UI gate for advertising AI features (buttons, checkboxes, CTAs): a surface
  # may only OFFER an AI action when the org has opted in (GDPR gate) AND a
  # usable configuration exists. Deliberately distinct from ai_enabled? —
  # "enabled but unconfigured" should surface setup hints, not feature buttons,
  # and has_valid_ai_configuration? alone advertised features to orgs that
  # never opted in ("offer, then refuse" UX the review flagged).
  def ai_available?(provider = AiCredential::PROVIDER_OPENAI)
    return false unless ai_enabled?

    # !! because has_valid_ai_configuration? can return nil (safe-navigation
    # branches inside) — view gates and specs rely on a real boolean.
    !!has_valid_ai_configuration?(provider)
  end

  # The provider this org's CHAT lane actually routes to. Delegated to the
  # factory that performs the routing rather than re-derived here: the drift
  # warning at Lalabase::Llm::Factory.chat_provider_name ("deriving it twice
  # would let the legal notice drift from the actual routing decision") applies
  # to the gate word for word — a gate answering for a different provider than
  # the request will reach is the "button lies" failure mode.
  def chat_provider_name
    Lalabase::Llm::Factory.chat_provider_name(self)
  end

  # Feature-keyed availability: "can this org use THIS feature?" — the question the
  # provider-keyed gates could not express (plan §3), because the answer hangs on
  # three axes: LANE (chat and embeddings route independently), PIN (does the path
  # follow the org's choice at all) and CAPABILITY (can that provider do the lane).
  # Every surface that approximated one of them built its own answer; this is the one
  # answer, and Lalabase::Llm::Factory.for_feature routes on the same registry row.
  #
  # Returns an Availability result, not a boolean, so a surface can NAME the reason
  # instead of silently withholding a button (plan E4). An unknown key raises
  # KeyError — a typo in a gate must not read as "not available".
  #
  # MEMOISED per instance (plan §7.6): a gate this convenient migrates into row
  # partials, and each resolution can hit AiCredential.active_for_provider
  # (Rails.cache → a Solid-Cache SELECT in production). The #368 lesson is why the
  # ANSWER is cached and not the resolver — Pundit memoised the policy INSTANCE, not
  # its answer, so the N+1 survived a guard spec. Lifetime is this object: a state
  # change within the same request needs a reloaded record, and the seam's own
  # fail-closed gates (§7.3) are what make that safe rather than merely stale.
  # @return [Lalabase::Llm::FeatureRegistry::Availability]
  def ai_available_for?(feature_key)
    @ai_availability ||= {}
    @ai_availability[feature_key.to_sym] ||= Lalabase::Llm::FeatureRegistry.resolve(feature_key, self)
  end

  # KI-Pakete P3 REMOVED ai_configured_for_chat? — "the configuration half of the
  # chat question, without the opt-in half". Its four callers (TicketSummaryService
  # plus the three summary entries in tickets/_ticket_content_for_frame) now ask
  # ai_available_for?(:ticket_summary).
  #
  # It was not merely redundant, it was WRONG for them: it derived the org's own
  # chat rung, while :ticket_summary is a utility path that routes on the package's
  # cheapest rung. With the two rungs on different credentials the answers diverged
  # in both directions — reproduced in the "the gate follows the rung the summary
  # routes on" pair in spec/services/ticket_summary_service_spec.rb.
  #
  # The narrower question was justified by keeping :ai_disabled and :no_api_key
  # apart, and that still holds — it just belongs to the CALLER now
  # (TicketSummaryService#unavailable_status maps the registry's reason), because
  # only the caller knows how many states its surface can render.
  #
  # R3 REMOVED the S4 pair ai_available_pinned? / ai_pinned_elsewhere?. Both
  # questions are now one reason on one answer: ai_available_for?(:customer_description)
  # is false with reason :pinned_elsewhere, and the registry asks the pin question
  # BEFORE the credential question for exactly the reason the pair was split in two —
  # "you route elsewhere" and "your credential is missing" need different remedies.
  # The pair's own regression (a usable credential for the pinned provider is NOT
  # enough) lives on in spec/models/organisation_spec.rb.

  # Get masked version of organisation's AI token for display purposes
  #
  # @return [String, nil] Masked token showing only prefix and last 8 characters
  def masked_ai_token
    return nil if ai_access_token.blank?

    case ai_provider || AiCredential::PROVIDER_OPENAI
    when AiCredential::PROVIDER_OPENAI
      "sk-#{'*' * 40}#{ai_access_token.last(8)}"
    when AiCredential::PROVIDER_ANTHROPIC
      "sk-ant-#{'*' * 80}#{ai_access_token.last(8)}"
    else
      '*' * 40 + ai_access_token.last(8)
    end
  end

  # Get AI usage statistics for this organisation
  #
  # @param days [Integer] Number of days to look back (default: 30)
  # @return [Hash] Hash with provider names as keys and token counts as values
  def ai_usage_stats(days = 30)
    ai_usages.recent(days).group(:provider).sum(:tokens_used)
  end

  # Monthly AI quota ledger for this org (gate decision + consumption UI).
  # Effective budget/buffer resolve the per-org override over the SystemSetting
  # default inside the ledger.
  # The two outcomes ai_connection_status may hold (L10). Constants rather than a DB
  # enum: the column answers ONE question with a closed set, and a string enum in
  # PostgreSQL would need a migration for a state we might add on a Tuesday. NULL is the
  # third state and deliberately has no constant — "never tested" is the absence of an
  # outcome, not an outcome, and giving it a name invites writing it.
  AI_CONNECTION_OK = 'ok'
  AI_CONNECTION_FAILED = 'failed'

  # True only for an access somebody has actually tried AND that answered. The access
  # card needs all three states apart: never tested, working, broken — collapsing the
  # first two into "not failed" is what made the hub card unable to warn (§3.2).
  def ai_connection_ok?
    ai_connection_status == AI_CONNECTION_OK
  end

  def ai_connection_failed?
    ai_connection_status == AI_CONNECTION_FAILED
  end

  def ai_connection_never_tested?
    ai_connection_checked_at.nil?
  end

  def ai_quota_ledger(now: Time.current)
    Lalabase::Llm::QuotaLedger.for(self, now: now)
  end

  # Get human-readable name for the organisation's AI provider
  #
  # @return [String] Display name for the configured AI provider
  def ai_provider_display_name
    AiCredential.provider_display_names[ai_provider] || ai_provider&.capitalize || 'Standard'
  end

  # Can the org's OWN chat token (BYOK) plausibly be used for `provider`?
  # Only shapes checkable WITHOUT a network call — the gate must not turn a page
  # render into an API request.
  #
  # PUBLIC since S7, and the reason is worth stating: this used to be a private
  # helper of has_valid_ai_configuration?, i.e. a READ that judged what was already
  # stored. Actors::SaveAiConfiguration asks the same question BEFORE the write, so
  # an unusable combination is refused instead of saved and then reported as "not
  # configured" by this very predicate. One definition for both directions — the
  # actor deliberately does not re-implement the branches below.
  #
  # The branches are deliberately asymmetric:
  # * openai — the historic sk-/org- prefix check, kept verbatim. It is the one
  #   format we own the knowledge of.
  # * google — Vertex is service-account-only; an API key would silently use the
  #   GLOBAL endpoint and void EU data residency (doc/ki_provider_dsgvo_plan.md
  #   §3.2). The rule already exists as a validation on the credential side —
  #   REUSED from AiCredentialProviderRules, not re-implemented, so there is one
  #   definition of "this is a service-account JSON".
  # * openai_compatible — no key format to check (the endpoint is a stranger's),
  #   but two settings are hard runtime raises in OpenAiCompatibleProvider:
  #   without api_base it has no endpoint, without a chat model no model (the
  #   BYOK path feeds it solely from preferred_chat_model). Unlike the embedding
  #   lane, the chat columns carry no presence validation, so an org CAN save a
  #   half-configured endpoint — and this gate is what keeps that from becoming a
  #   button that 500s.
  # * anthropic and anything else implemented later — presence is all we can
  #   honestly assert. A guessed format that answers "no" would hide a working
  #   configuration, which is the same lie in the other direction.
  def own_ai_token_usable?(provider)
    return false if ai_access_token.blank?

    case provider
    when AiCredential::PROVIDER_OPENAI
      ai_access_token.length > 20 &&
        (ai_access_token.start_with?('sk-') || ai_access_token.start_with?('org-'))
    when AiCredential::PROVIDER_GOOGLE
      google_service_account_token?(ai_access_token)
    when AiCredential::PROVIDER_OPENAI_COMPATIBLE
      ai_api_base.present? && preferred_chat_model.present?
    else
      true
    end
  end

  private

  # A foreign project is out of reach of every reader of this column, an
  # archived one would be an inbox that takes nothing from the first moment.
  def meeting_inbox_project_usable
    return if meeting_inbox_project_id.nil?

    project = ActsAsTenant.with_tenant(self) { projects.find_by(id: meeting_inbox_project_id) }
    errors.add(:meeting_inbox_project_id, :not_usable) if project.nil? || project.archived?
  end

  # The embedding twin of own_ai_token_usable?, on the independent embedding_*
  # columns. Same branches for the same reasons (the sk-/org- rule is the one key
  # format we own the knowledge of; Vertex is service-account-only or EU residency is
  # void; an openai_compatible endpoint without base URL or model is a hard runtime
  # raise) — only the columns differ. Here the openai_compatible branch mirrors a
  # validation that ALREADY exists (embedding_api_base + embedding_model are required
  # once an own embedding token is present), so it can only ever fire for rows written
  # before that validation.
  def own_embedding_token_usable?(provider)
    return false if embedding_access_token.blank?

    case provider
    when AiCredential::PROVIDER_OPENAI
      embedding_access_token.length > 20 &&
        (embedding_access_token.start_with?('sk-') || embedding_access_token.start_with?('org-'))
    when AiCredential::PROVIDER_GOOGLE
      google_service_account_token?(embedding_access_token)
    when AiCredential::PROVIDER_OPENAI_COMPATIBLE
      embedding_api_base.present? && embedding_model.present?
    else
      true
    end
  end

  # System-credential tier for the embedding lane. Two differences from the chat twin,
  # both load-bearing:
  # * PURPOSE: a credential serves this lane only when its purpose includes embeddings
  #   (AiCredentialPricing::EMBEDDING_PURPOSES). A chat-only credential is a perfectly
  #   good chat credential and no embedding configuration at all — and it is the one
  #   question the chat predicate structurally cannot ask.
  # * NO ENV fallback: the chat twin's rescue falls back to the OpenAI ENV token
  #   because Organisation#ai_client once did. The embedding path
  #   (Factory#resolve_embedding_credentials) has never read ENV, so promising it here
  #   would open a gate on a credential the request cannot use.
  def system_embedding_credential_usable?(provider)
    credential = AiCredential.active_for_provider(provider)
    return false unless credential&.usable_for?(:embedding)

    # The MODEL half stays here, because it is the one condition #usable_for? cannot
    # answer: on the SYSTEM path the Factory takes the model from the credential
    # (default_model), while the org's own embedding_model only feeds the BYOK path —
    # so this is an org-relative question, not a property of the record.
    #
    # The endpoint half moved INTO #usable_for?. It used to be spelled out here as
    # additional_config['uri_base'] alone, which made this gate the one place still
    # blind to the api_base COLUMN: the Factory routed a column-only credential
    # happily while this predicate told the customer semantic search was unavailable.
    return credential.default_model.present? if provider == AiCredential::PROVIDER_OPENAI_COMPATIBLE

    true
  rescue StandardError
    # Credential lookup itself failed (cache/DB) — a view gate must not raise.
    false
  end

  # The package rung of the embedding lane (KI-Pakete P2). Judges the credential
  # the routing WILL use, so the three refusals below are exactly the three
  # Factory#curated_embedding_resolution raises on:
  # * a rung of another provider — the caller asked about a lane this org does
  #   not route (a pinned feature, or a stale provider argument),
  # * disabled, and
  # * a purpose that excludes embeddings.
  #
  # No model half here, unlike the system twin: a curated package always carries its
  # own embedding_model (E11, presence validated), so the three shared conditions are
  # the whole answer — and they are the record's own (#usable_for?), not a copy.
  def curated_embedding_credential_usable?(credential, provider)
    credential.provider == provider && credential.usable_for?(:embedding)
  end

  # One definition of "service-account JSON": the credential-side validation. Takes
  # the token so both lanes (chat BYOK and embedding BYOK) share the single rule
  # instead of each carrying a copy.
  def google_service_account_token?(token)
    parsed = JSON.parse(token)
    parsed.is_a?(Hash) &&
      AiCredentialProviderRules::GOOGLE_SERVICE_ACCOUNT_KEYS.all? { |key| parsed[key].present? }
  rescue JSON::ParserError
    false
  end

  # System-credential tier. The ENV fallback below is reached ONLY when the
  # credential lookup RAISES — that was already true before S1c (the old code did
  # an unconditional `return system_credential&.enabled?`), and it is preserved
  # rather than "fixed": making ENV a real fallback would silently re-open an
  # OpenAI lane for orgs whose system credential was deliberately deactivated.
  def system_ai_credential_usable?(provider)
    credential = AiCredential.active_for_provider(provider)
    return false unless credential&.enabled?

    # Mirrors the openai_compatible branch of own_ai_token_usable? (BYOK tier).
    # Without this the two halves of the SAME gate answered differently: BYOK
    # demanded a model, the system tier accepted a credential that cannot name
    # one. OpenAiCompatibleProvider#default_chat_model has no constant fallback
    # (it talks to Mistral, Ollama, vLLM … — there is no honest default), so it
    # raises, and the org saw an offered button die in a flash.
    #
    # ONLY the credential's default_model, and that is a change: this branch used to
    # accept the org's preferred_chat_model as a substitute, because
    # Factory#resolve_credentials let that column win over the credential here. The
    # review of S7 removed that override (the system key names its own model), so
    # accepting it here would be a gate answering about a value the request no longer
    # reads — it would report "configured" and OpenAiCompatibleProvider#default_chat_model
    # would then raise, which is precisely the failure this branch exists to prevent.
    # New Admin credentials must carry a default_model anyway (validation); this covers
    # the rows that already exist.
    return credential.default_model.present? if provider == AiCredential::PROVIDER_OPENAI_COMPATIBLE

    true
  rescue StandardError
    # Credential lookup itself failed (cache/DB) — a view gate must not raise.
    provider == AiCredential::PROVIDER_OPENAI && openai_env_token_usable?
  end

  def openai_env_token_usable?
    token = Rails.application.credentials.openai&.access_token || ENV['OPENAI_ACCESS_TOKEN']
    token.present? && token.length > 20 &&
      (token.start_with?('sk-') || token.start_with?('org-'))
  end
end
