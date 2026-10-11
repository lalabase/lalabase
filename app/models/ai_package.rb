# frozen_string_literal: true

# A curated AI provider bundle (KI-Pakete, doc/ki_pakete_plan.md §2/§6): one
# legal jurisdiction + one FIXED embedding triple (credential, model, dims —
# E11: the package owns the full vector-space triple, never inherited from
# credential.default_model) + a ladder of chat tiers (AiPackageTier). The
# embedding half hangs on axis 1 (jurisdiction) and NEVER on axis 2
# (performance tier) — otherwise a cheap tier switch would trigger a full
# reindex (§2, the plan's central claim).
#
# GLOBAL table: operator-curated offerings, not tenant data — no acts_as_tenant,
# no Admin:: twin (pattern: PromptPersona). The admin UI creates only
# kind: 'curated'; a physical 'custom' row (card "Eigene Konfiguration") is a
# P2 decision and would come from db/seeds, never the form (§7b.1).
#
# `active` here means "published in the customer catalogue" — deliberately NOT
# the credentials' "Standard" semantics (§7b.1: the word "aktiv" is already
# taken twice).
# == Schema Information
#
# Table name: ai_packages
#
#  id                      :uuid             not null, primary key
#  active                  :boolean          default(FALSE), not null
#  description             :text
#  embedding_dims          :integer
#  embedding_model         :string
#  jurisdiction            :string
#  kind                    :string           default("curated"), not null
#  name                    :string           not null
#  position                :integer          default(0), not null
#  processing_region       :string
#  provider_note           :text
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  embedding_credential_id :uuid
#
# Indexes
#
#  index_ai_packages_on_embedding_credential_id  (embedding_credential_id)
#  index_ai_packages_on_name                     (name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (embedding_credential_id => ai_credentials.id)
#
class AiPackage < ApplicationRecord
  KINDS = %w[curated custom].freeze
  # The shop-window rung: the only kind the admin form creates (§7b.1).
  CURATED = 'curated'
  # The four fields of the §3 matrix + self-hosting: a Vertex europe-west3
  # package is 'eu_region_foreign_provider' — labelling it 'eu_native' would be
  # a false legal claim (jurisdiction feeds the AVV, §9 Falle 6).
  #
  # ① EU company, EU processing.
  EU_NATIVE = 'eu_native'
  # ② Non-EU company on an EU region — the juristically HARD field (§3.1), not
  # the half-harmless one: remote access from a third country is itself a
  # transfer.
  EU_REGION_FOREIGN_PROVIDER = 'eu_region_foreign_provider'
  # ③ EU company on a third-country server (E12) — previously inexpressible and
  # forced into a firm-seat-erasing non_eu.
  EU_PROVIDER_FOREIGN_REGION = 'eu_provider_foreign_region'
  # ④ Neither.
  NON_EU = 'non_eu'
  # A THIRD axis, not a fifth field (§3.2): it answers "who is the processor",
  # not "where". Hence exempt from the matrix and from its consistency check.
  SELF_HOSTED = 'self_hosted'
  JURISDICTIONS = [EU_NATIVE, EU_REGION_FOREIGN_PROVIDER, EU_PROVIDER_FOREIGN_REGION,
                   NON_EU, SELF_HOSTED].freeze

  # The §3 matrix as DATA, keyed [company in the EU?, processing in the EU?].
  # Deriving the rung instead of believing the form is the whole of E12 — and it
  # is also what makes the two customer filters (§7.1) possible, because a filter
  # can only filter on an axis that exists as its own value.
  JURISDICTION_MATRIX = {
    [true, true] => EU_NATIVE,
    [false, true] => EU_REGION_FOREIGN_PROVIDER,
    [true, false] => EU_PROVIDER_FOREIGN_REGION,
    [false, false] => NON_EU
  }.freeze

  # Badge colours live next to the rungs they colour, not as loose literals in a
  # view: a fifth rung added above would otherwise fall through to a silent grey
  # badge with nothing failing. A guard spec pins the two lists equal.
  # ③ sits between ② and ④ on purpose: the data physically leaves the EU (worse
  # than ②), but the processor is an EU company (better than ④).
  JURISDICTION_BADGE_STYLES = {
    EU_NATIVE => 'bg-green-100 text-green-800',
    EU_REGION_FOREIGN_PROVIDER => 'bg-yellow-100 text-yellow-800',
    EU_PROVIDER_FOREIGN_REGION => 'bg-orange-100 text-orange-800',
    NON_EU => 'bg-red-100 text-red-800',
    SELF_HOSTED => 'bg-blue-100 text-blue-800'
  }.freeze
  # ── Training and retention: DERIVED, never stored ────────────────────────────
  #
  # The values and the evidence live on AiCredentialContract, because that is
  # where the contract is. A package merely reads its credentials — the same
  # construction as the jurisdiction, and for the same reason: a stored copy
  # would drift from the contract the moment a provider revises its terms.
  #
  # Same pairing rule as the jurisdiction badges: a value without a style would
  # fall through to a silent grey badge, so a guard spec pins the lists equal.
  TRAINING_USAGE_BADGE_STYLES = {
    AiCredentialContract::TRAINING_EXCLUDED => 'bg-green-100 text-green-800',
    AiCredentialContract::TRAINING_USED => 'bg-red-100 text-red-800',
    AiCredentialContract::TRAINING_UNSPECIFIED => 'bg-gray-100 text-gray-700'
  }.freeze

  # AiCredential#region is a two-value select ('eu'/'us', _seam_fields.html.erb)
  # WITHOUT a blank-guard, so 'unknown' is a real, common third state.
  US_REGION = 'us'
  EU_REGION = 'eu'
  # The DEGRADED company-seat answer, kept for exactly one case: a credential
  # whose company_domicile nobody recorded. Where the field IS set it decides
  # (E12) — a provider name can never answer the question for the three EU
  # presets, which all run as 'openai_compatible' (§3.4).
  FOREIGN_PROVIDER_IN_EU = AiCredential::PROVIDER_GOOGLE
  # Vertex states its processing location in additional_config['location']
  # ('europe-west3', 'us-central1', 'global'), not in the coarse region select —
  # so the EU test there is the region-name prefix, and 'global' is correctly NOT
  # an EU location (it is the fallback that breaks EU residency, §4 point 3).
  VERTEX_EU_LOCATION_PREFIX = 'europe'
  # Below this, the batched lookup IS the single lookup it would replace.
  MIN_TIERS_TO_BATCH = 2

  has_many :tiers, -> { order(:position) }, class_name: 'AiPackageTier',
                                            dependent: :destroy, inverse_of: :ai_package
  belongs_to :embedding_credential, class_name: 'AiCredential', optional: true

  # Fixed-slot tier editing (§7b.1 option C): the form renders exactly the
  # tiers built here — static child indexes, so the project-known nested
  # attributes integer-key trap cannot bite.
  accepts_nested_attributes_for :tiers

  # The customer catalogue (§7), arriving with P2 — the slice that has the query
  # that needs it. `active` means "published in the customer catalogue" and
  # nothing else; an unpublished package stays fully editable and is simply not
  # on offer (Actors::SelectAiPackage refuses it too). Curated-only (adversarial
  # review P2-B1): a published custom row would reach the catalogue's
  # embedding_switch_for? probe with no credentials and 500 every org's AI
  # settings page — the "Eigene Konfiguration" card is a hand-built view
  # element, never a database row on offer.
  scope :published, -> { where(active: true, kind: CURATED) }
  scope :ordered, -> { order(:position, :name) }
  # Everything a customer card asserts about a package, in one go. All three
  # derived answers walk package → credentials → assessed versions, and
  # AiCredentialContractTerms#contract_on filters in memory ONLY when the
  # contracts association is loaded — without this leg every card pays one query
  # per referenced credential. The scope exists so that precondition has a NAME
  # instead of living as an identical `includes` hash at each call site; it was
  # already written out three times before the training badge needed the fourth.
  scope :with_customer_claims, lambda {
    includes(embedding_credential: :contracts, tiers: { chat_credential: :contracts })
  }

  validates :kind, inclusion: { in: KINDS }
  # The name is the card headline in the customer catalogue (§7) — two cards
  # called the same thing are indistinguishable there. Backed by a unique index.
  validates :name, presence: true, uniqueness: true

  # Mandatory-ness follows `kind`, deliberately: `curated` is the shop window and
  # must be complete, while `custom` is the placeholder row for "the org's own
  # settings" (E1) that carries no embedding triple at all — a blanket presence
  # rule would reject the very seeds line P2 may add.
  #
  # The credential is required on the ASSOCIATION, not on embedding_credential_id:
  # a package whose credential is not saved yet has one, it just has no id — and
  # the association name is where vanilla Rails reports a required belongs_to too.
  validates :description, :provider_note, :jurisdiction, :embedding_model, :embedding_dims,
            :embedding_credential, presence: true, if: :curated?
  validates :jurisdiction, inclusion: { in: JURISDICTIONS }, allow_blank: true
  # Same list Organisation and EmbeddingSpace validate against: a dimension
  # outside it has no storage/index lane, so the package would promise a vector
  # space nothing can serve.
  validates :embedding_dims, inclusion: { in: ::Organisation::SUPPORTED_DIMS, message: :supported_dimension },
                             allow_nil: true

  # Every tier resolves its chat credential while validating, so a form that
  # submits both rungs runs the same single-row lookup twice — an N+1 the app's
  # guard rightly flags on every package save. Batching it here rather than in
  # the controller keeps it true for seeds and the console as well.
  before_validation :preload_tier_credentials
  # `position` is NOT NULL with a DB default, but a cleared number_field submits
  # "" — which ActiveRecord casts to nil and writes EXPLICITLY, so the default
  # never applies and the INSERT dies on the constraint. Blank ordering means
  # "first" here, so normalising is the honest reading, not a workaround.
  before_validation :normalise_blank_position

  # The admin selects offer exactly these sets already (§7b.1); this catches
  # manipulation and the race where a credential is disabled after the form was
  # rendered.
  validate :embedding_credential_must_be_embedding_capable
  validate :jurisdiction_must_not_contradict_credentials
  validate :embedding_model_must_exist_in_vertex_region, if: :embedding_vertex_check_due?
  # The DB index on (ai_package_id, key) cannot produce a form error — it raises
  # RecordNotUnique from inside the INSERT. In-memory siblings of one package
  # never see each other through AiPackageTier's own uniqueness query (they are
  # not persisted yet), so the readable error has to be stated HERE, on the
  # parent that actually holds both rungs.
  validate :tier_keys_must_be_unique
  # A PUBLISHED curated package is a promise the customer acts on: they pick the
  # card, and every rung has to answer. Nothing else enforced the ladder — a
  # package with zero tiers (or only 'fast') validated, saved AND published, and
  # the customer would have seen an offering with no chat model behind it. The
  # form always posts both slots, so this only bites the paths that bypass it:
  # seeds, console, a POST omitting tiers_attributes.
  #
  # Deliberately scoped to `active?`, not to every curated row: an UNPUBLISHED
  # package is explicitly the draft state ("Unveröffentlichte Pakete lassen sich
  # in Ruhe fertig pflegen"), and a legacy one-rung row must stay editable long
  # enough to complete it.
  validate :published_package_must_carry_the_full_ladder, if: -> { curated? && active? }

  # CACHE-ONLY Vertex lookup, shared with AiPackageTier (E9, §9 Falle 3):
  # returns the credential's region when the cached matrix KNOWS the model is
  # absent there — a clear 404 — and nil for EVERY other outcome (cold cache,
  # unknown status, or a model the matrix does not cover). Only certainty may
  # block a save: a Google outage must not stop an operator from maintaining a
  # package, but the one finding that reliably predicts "silently broken" must.
  #
  # Deliberately `.cached`, NOT `.call` — this runs from a `validate`, and Rails
  # opens the save transaction BEFORE validation. A cold-cache `.call` fans out
  # 5 regions × up to 6 models at concurrency 8 with a 5 s per-request timeout
  # (~40 s), holding a PG connection idle-in-transaction the whole time — on a
  # production Puma with RAILS_MAX_THREADS=1 × WEB_CONCURRENCY=2, i.e. two
  # request slots total. A package referencing three google credentials would
  # take the whole app offline for minutes on one save. The fresh probe has its
  # own explicit, operator-triggered action (#vertex_check); a cold cache is
  # simply the "ungeprüft" state E9 already models. This DEVIATES from plan
  # §7b.1 ("bei leerem Cache ein frischer Lauf") — the plan predates the
  # two-slot measurement.
  #
  # Lives here rather than in a shared concern because it has exactly two call
  # sites in one domain; a third would be the moment to extract it.
  def self.unavailable_vertex_region(credential:, model:)
    region = credential.additional_config&.dig('location').to_s
    return nil if region.blank? || model.blank?

    matrix = Lalabase::Llm::VertexAvailabilityProbe.cached(credential_id: credential.id)
    cell = matrix&.dig(:results)&.find { |result| result[:region] == region && result[:model] == model }
    return nil unless cell && cell[:status_code] == 404

    region
  rescue Lalabase::Llm::VertexAvailabilityProbe::ProbeError, Lalabase::Llm::Provider::Error,
         ActiveRecord::RecordNotFound => e
    # The "ungeprüft" case (E9), narrowed on purpose: a blanket rescue would
    # also swallow a NoMethodError from a changed matrix shape and turn our own
    # bug into a permanently green save path.
    Rails.logger.warn("[ai_package] vertex cache skipped for credential #{credential.id}: #{e.class}: #{e.message}")
    nil
  end

  # The reverse of #referenced_credentials, for a whole page of credentials at
  # once: which packages point AT each of the given credentials. Two grouped
  # queries regardless of how many rows the admin list renders — the same reason
  # Admin::AiCredentialsController aggregates usage in one pass instead of per
  # row.
  #
  # Shape:
  #   { credential_id => [{ package: <AiPackage>, role: :embedding, label: nil },
  #                       { package: <AiPackage>, role: :tier, label: 'Gründlich' }] }
  #
  # `label` carries the tier's operator-facing rung name (AiPackageTier#label)
  # and is nil for the embedding slot, whose role already IS its label. A
  # credential nobody references has NO key — callers fetch with a [] default,
  # so an unreferenced row costs nothing.
  def self.references_by_credential(credential_ids)
    ids = Array(credential_ids).compact.uniq
    return {} if ids.empty?

    references = {}

    where(embedding_credential_id: ids).ordered.each do |package|
      (references[package.embedding_credential_id] ||= []) << { package: package, role: :embedding, label: nil }
    end

    tiers_for(ids).each do |tier|
      (references[tier.chat_credential_id] ||= []) << { package: tier.ai_package, role: :tier, label: tier.label }
    end

    references
  end

  # Ordered by package first so a credential's badges group by package rather
  # than interleaving two packages' rungs. Separate order arguments (not one
  # comma-joined string) so Rails accepts them as attribute references.
  def self.tiers_for(credential_ids)
    AiPackageTier.where(chat_credential_id: credential_ids)
                 .includes(:ai_package).references(:ai_package)
                 .order('ai_packages.position', 'ai_packages.name', 'ai_package_tiers.position')
  end
  private_class_method :tiers_for

  def curated?
    kind == CURATED
  end

  # Every credential this package points at — its own embedding slot plus one
  # per tier. The jurisdiction claim is a statement about ALL of them.
  def referenced_credentials
    ([embedding_credential] + tiers.map(&:chat_credential)).compact.uniq
  end

  # The training answer the customer card shows: STRICTEST of the referenced
  # credentials' assessments on `date`. A package is only as good as its weakest
  # credential — one that trains makes the whole package "trains", one nobody
  # assessed makes it "not assured". Never the other way round.
  #
  # nil for self-hosted packages: there the question is GROUNDLESS, not
  # unanswered — no third party receives data at all, and a grey "not assured"
  # badge would be a false warning. The card makes the same exception for the
  # legal classification.
  # @return [String, nil]
  def derived_training_usage(date = Date.current)
    return nil if jurisdiction == SELF_HOSTED

    answers = referenced_credentials.map { |credential| credential.training_usage_on(date) }
    strictest(AiCredentialContract::TRAINING_SEVERITY, answers,
              AiCredentialContract::TRAINING_UNSPECIFIED)
  end

  # The retention answer, same construction. Returns [policy, days] — days only
  # for 'limited', and then the HIGHEST of the involved credentials: naming the
  # smaller one would be the prettier and therefore false statement.
  # @return [Array(String, Integer), nil]
  def derived_retention(date = Date.current)
    return nil if jurisdiction == SELF_HOSTED

    assessments = referenced_credentials.map { |credential| credential.contract_on(date) }
    policies = assessments.map { |c| c&.retention_policy || AiCredentialContract::RETENTION_UNSPECIFIED }
    worst = strictest(AiCredentialContract::RETENTION_SEVERITY, policies,
                      AiCredentialContract::RETENTION_UNSPECIFIED)
    return [worst, nil] unless worst == AiCredentialContract::RETENTION_LIMITED

    days = assessments.compact.filter_map(&:retention_days).max
    # "Befristet" without a number is not a statement that can be written down.
    # Instead of claiming a period nobody has quantified, the answer falls back to
    # "nicht zugesichert": the WORSE value in the severity order, so fail closed.
    # The validation requires the number for `limited`; the case is reachable only
    # via update_column, import or SQL. But the outcome would be a raw locale hash
    # on the customer card, and that is too bad to allow.
    return [AiCredentialContract::RETENTION_UNSPECIFIED, nil] if days.nil?

    [worst, days]
  end

  # The sub-processor answer, same construction as the training one. The third
  # axis of the assessment — a provider that names nobody is a worse answer for
  # the whole package than one that does, no matter how many others disclose.
  # @return [String, nil]
  def derived_subprocessors_disclosure(date = Date.current)
    return nil if jurisdiction == SELF_HOSTED

    answers = referenced_credentials.map { |credential| credential.subprocessors_disclosure_on(date) }
    strictest(AiCredentialContract::SUBPROCESSORS_SEVERITY, answers,
              AiCredentialContract::SUBPROCESSORS_UNSPECIFIED)
  end

  # The rung with this key, or nil. The ONE lookup the two questions below share,
  # so "which row does key X mean" is answered in a single place.
  # @return [AiPackageTier, nil]
  def tier_for(key)
    tiers.detect { |tier| tier.key == key }
  end

  # The rung a package SELECTION lands on when the request names none — i.e. what
  # Actors::SelectAiPackage resolves for a blank ai_package_tier_key, and what the
  # catalogue card must therefore judge before offering its button (KI-Pakete P3).
  #
  # Deliberately WITHOUT #utility_tier's fallback, and the difference is the point:
  # a helper path may never be taken off chat, so utility_tier degrades to the
  # lowest rung it can find. A SELECTION with no default rung is a data fault the
  # Actor names out loud (:tier_not_offered) — degrading there would silently put
  # the customer on a rung they did not ask for. Same table, two questions, two
  # failure semantics.
  # @return [AiPackageTier, nil] nil = this package cannot be selected as-is
  def default_selection_tier
    tier_for(AiPackageTier::DEFAULT_KEY)
  end

  # Would a fresh selection of this package be refused? The card's half of
  # "Door 1 of 2" — it must ask the SAME row the Actor will, or it offers a button
  # whose only outcome is an error message.
  #
  # Covers exactly the two refusals reachable on a blank-tier selection: no default
  # rung at all, and a default rung whose credential can no longer serve chat.
  # #usable_for?(:chat), not `enabled?` — the Factory refuses on all three of its
  # conditions (enabled, purpose, endpoint; curated_chat_resolution), so a door
  # asking fewer questions would wave through a selection the routing then raises on.
  def selection_tier_unusable?
    tier = default_selection_tier
    tier.nil? || !tier.chat_credential&.usable_for?(:chat)
  end

  # The instance form of the `published` scope — ONE rule, asked in both directions.
  #
  # It exists because P4c (E5) puts a card on screen that the scope did NOT select:
  # an org keeps running on a package the operator has since withdrawn, and it must
  # see that package rather than an empty catalogue. From there the card has to know
  # what it is looking at, because Actors::SelectAiPackage#resolve_package refuses
  # EVERY write on an unpublished row (:package_not_published) — rung changes
  # included. Rendering its Leistungsstufen-switcher as live buttons would offer
  # clicks whose only possible outcome is a flash error.
  def published?
    active? && curated?
  end

  # THE rung helper paths run on (KI-Pakete P3, doc/ki_pakete_plan.md §2.1):
  # 'fast' when this package has one, otherwise the LOWEST rung it does have
  # (tiers are ordered by position).
  #
  # The fallback is not decoration. A package predating the 'fast' key, or one an
  # operator built with a single 'thorough' rung, has no 'fast' row — answering
  # nil there would take a helper path off chat entirely, i.e. break a working
  # feature in order to save money on it.
  #
  # It lives on the model rather than in the Factory because TWO places need the
  # same answer and must not derive it twice: the routing (Factory#curated_tier
  # returns this row for `utility: true`) and the customer-facing hint that NAMES
  # the rung (ai_settings/_package_tier_switch). A second derivation in the view
  # is how the screen ends up promising a rung the request does not use.
  # @return [AiPackageTier, nil] nil only for a package with no rungs at all
  def utility_tier
    tier_for(AiPackageTier::DEFAULT_KEY) || tiers.min_by(&:position)
  end

  # Non-blocking counterpart to the jurisdiction validation, for the admin form
  # (§7b.1 point 3): an 'eu_native' package whose processor is a non-EU company
  # is not wrong, it is mislabelled — §3 calls that rung
  # 'eu_region_foreign_provider'. Returns the credentials that trigger that
  # reading; [] means nothing to say.
  #
  # Since E12 the FIELD decides where it is set, and the provider name is only
  # the fallback for credentials nobody classified. That is also why this stays
  # a warning while the processing axis blocks: company_domicile is NULL on every
  # row written before the column existed, so an unrecorded seat may not
  # invalidate a package — an unrecorded REGION always could, and still does.
  def jurisdiction_warnings
    return [] unless jurisdiction == EU_NATIVE

    referenced_credentials.select { |credential| foreign_company_hint?(credential) }
  end

  # The §3 rung READ OFF the credentials (E12) — the honest counterpart to the
  # `jurisdiction` the operator claims. nil when at least one axis is not
  # derivable: a package whose credentials nobody classified has no derivable
  # rung, and answering 'non_eu' there would be as much an invention as
  # answering 'eu_native'.
  #
  # Aggregated per AXIS, not per credential, and that is what "the worse
  # classification wins" (§3) means once more than one credential is involved: a
  # package holding a ② credential next to a ③ one has a non-EU company AND
  # non-EU processing in it, so it is ④ — which no per-credential ranking could
  # produce, because ② and ③ are not ordered against each other (§7.1).
  # @return [String, nil]
  def derived_jurisdiction
    return nil if referenced_credentials.empty?

    company = company_axis
    processing = processing_axis
    return nil if company.nil? || processing.nil?

    JURISDICTION_MATRIX[[company, processing]]
  end

  # The rung a customer-facing surface may STATE (§3.3): the derived rung where
  # it exists — recomputed from the credentials' two axes, so it cannot drift
  # away from the facts — else the stored claim, which is also what the AVV says
  # for packages whose credentials nobody classified yet.
  #
  # self_hosted is the THIRD axis (§3.2), deliberately outside the §3 matrix the
  # derivation answers — deriving there would relabel a self-hosted package as ①
  # and erase the "operator is the processor" claim (adversarial review P2-B3).
  # Flipping the general order instead is NOT the fix: the drift case (mutation
  # M4) relies on derivation winning for matrix rungs.
  #
  # Shared by the catalogue card and the chat's Art. 13 notice (P5) — the same
  # claim must read the same everywhere, so the branch lives here, not in views.
  # @return [String, nil] nil/blank = nothing classified and nothing claimed
  def effective_jurisdiction
    return jurisdiction if jurisdiction == SELF_HOSTED

    derived_jurisdiction.presence || jurisdiction
  end

  # Filter axis 1 of §7.1 — "EU company". FAIL CLOSED: an unrecorded seat is not
  # an EU seat, so the strictest filter setting (the default) hides a package
  # nobody vouched for rather than showing it.
  def eu_company?
    company_axis == true
  end

  # Filter axis 2 of §7.1 — "processing in the EU only". Same fail-closed rule.
  def eu_processing_only?
    processing_axis == true
  end

  # Would putting this org on this package MOVE its embedding lane? P2 refuses
  # exactly that switch: a new lane needs a reindex, and the seamless one is
  # P4's guided path (§8, E5).
  #
  # The card's entry point into Factory#embedding_switch?, which is also what
  # Actors::SelectAiPackage and the "Eigene Konfiguration" card ask. It stays a
  # method on the package so the card partial reads `package.embedding_switch_for?`
  # rather than reaching into the Factory — but it must NOT re-derive the answer:
  # the comparison used to live here as well as in the Actor, and the third door
  # (deselection) then quietly had no comparison at all.
  def embedding_switch_for?(organisation)
    Lalabase::Llm::Factory.embedding_switch?(organisation, package: self)
  end

  private

  # The strictest value by the severity order, with a fail-closed outcome for
  # everything that does NOT appear in the order. Third appearance of the same
  # aggregation (training, retention, sub-processors), hence once here instead
  # of three times.
  #
  # `find` alone returns nil for an unknown value, and on the customer card nil
  # means "self_hosted, so no badge": a row with no statement at all instead of
  # a warning. Exactly the silent all-clear the card is built against (D4). The
  # empty answer set takes the same exit: a package without credentials has
  # assured nothing. Answering both cases together here saves the third
  # hand-maintained copy of the same rule.
  #
  # An unknown value requires that the inclusion validation was bypassed
  # (update_column, import, SQL). It stays reachable anyway, and the outcome is
  # too bad to leave to chance.
  def strictest(severity, answers, fallback)
    severity.find { |value| answers.include?(value) } || fallback
  end

  # ── the two axes of §3, as tri-states ──────────────────────────────────────
  # true = every referenced credential is inside, false = at least one provably
  # is not, nil = nobody said (and none is provably outside).
  #
  # FALSE BEATS NIL, deliberately: one credential known to sit outside settles
  # the axis for the whole package no matter what the others left blank — which
  # is how the US-region check survives E12 even on rows with no company seat.
  def company_axis
    axis_of(referenced_credentials) { |credential| eu_company_credential?(credential) }
  end

  def processing_axis
    axis_of(referenced_credentials) { |credential| eu_processing_credential?(credential) }
  end

  def axis_of(credentials, &answer)
    # Fail-closed on emptiness (adversarial review P2-B2): a package nobody
    # vouches for must not pass the strictest filters — an all-true fold over
    # zero credentials would put exactly that package into the default view.
    return false if credentials.empty?

    answers = credentials.map(&answer)
    return false if answers.include?(false)
    return nil if answers.include?(nil)

    true
  end

  # The FIELD alone, deliberately (E12): a provider name is not a company seat,
  # and the three EU presets all run as 'openai_compatible', so a name-based
  # answer would be blind for exactly the credentials this axis exists for. An
  # unrecorded seat is therefore unknown here — never "EU", never "outside".
  # @return [Boolean, nil] nil = not recorded
  def eu_company_credential?(credential)
    return nil if credential.company_domicile.blank?

    credential.company_domicile == AiCredential::COMPANY_DOMICILE_EU
  end

  # The DEGRADED reading, for warnings only. It may guess where the axis above
  # may not, because a warning that turns out wrong costs an operator a second
  # look while a wrong ERROR would make a legitimate package unsaveable — and
  # the guess is the pre-E12 rule, kept exactly as loud as it was.
  def foreign_company_hint?(credential)
    return credential.company_domicile == AiCredential::COMPANY_DOMICILE_NON_EU if credential.company_domicile.present?

    credential.provider == FOREIGN_PROVIDER_IN_EU
  end

  # @return [Boolean, nil] nil = not recorded
  def eu_processing_credential?(credential)
    return nil unless credential.residency_stated?
    return vertex_eu_location?(credential) if credential.provider == FOREIGN_PROVIDER_IN_EU

    # Anything outside the two-option select is stated but not placeable, and
    # falls through to nil: unknown, NOT "non-EU". Inventing either direction
    # from a string nobody defined is what §3 exists to prevent.
    case credential.region
    when EU_REGION then true
    when US_REGION then false
    end
  end

  def vertex_eu_location?(credential)
    credential.additional_config['location'].to_s.start_with?(VERTEX_EU_LOCATION_PREFIX)
  end

  def normalise_blank_position
    self.position = 0 if position.blank?
  end

  # Every rung the parent holds must be distinct — the DB index says so, and it
  # says it by raising rather than by filling in errors.
  def tier_keys_must_be_unique
    keys = tiers.reject(&:marked_for_destruction?).map { |tier| tier.key.to_s.presence }.compact
    duplicates = keys.tally.select { |_key, count| count > 1 }.keys
    return if duplicates.empty?

    errors.add(:tiers, :duplicate_key, keys: duplicates.sort.join(', '))
  end

  def published_package_must_carry_the_full_ladder
    present = tiers.reject(&:marked_for_destruction?).map { |tier| tier.key.to_s }
    missing = AiPackageTier::KEYS - present
    return if missing.empty?

    errors.add(:tiers, :incomplete_ladder, keys: missing.join(', '))
  end

  # Only the tiers already in memory: the nested form builds both rungs before
  # validating, which is exactly the case worth batching, while an untouched
  # package must not pay a tier query for it. Credentials that no longer exist
  # stay unassigned so the presence check still reports them.
  #
  # STALENESS, not `loaded?`: on the update path the controller eager-loads
  # `tiers: :chat_credential`, and a nested-attributes write to chat_credential_id
  # leaves the association `loaded?` while making its target STALE. Filtering on
  # `loaded?` alone therefore emptied `pending` on exactly the path this exists
  # for, and Rails re-fetched one credential per rung — the N+1 Prosopite raises
  # on (spec/support/prosopite.rb arms every example with raise = true).
  def preload_tier_credentials
    pending = tiers.target.reject do |tier|
      association = tier.association(:chat_credential)
      association.loaded? && !association.stale_target?
    end
    return if pending.size < MIN_TIERS_TO_BATCH

    credentials = AiCredential.where(id: pending.filter_map(&:chat_credential_id).uniq).index_by(&:id)
    pending.each do |tier|
      credential = credentials[tier.chat_credential_id]
      tier.chat_credential = credential if credential
    end
  end

  def embedding_credential_must_be_embedding_capable
    return if embedding_credential.nil?

    embedding_purposes = AiCredentialPricing::EMBEDDING_PURPOSES
    errors.add(:embedding_credential, :disabled) unless embedding_credential.enabled?
    errors.add(:embedding_credential, :wrong_purpose) unless embedding_purposes.include?(embedding_credential.purpose)
    return if AiCredential.embedding_capable_providers.include?(embedding_credential.provider)

    errors.add(:embedding_credential, :not_embedding_capable, provider: embedding_credential.provider)
  end

  # The claim checked against the derived rung (E12), axis by axis. Not a matter
  # of taste: the claim ends up in the AVV (§9 Falle 6), and reading it off the
  # credential facts is more truth than any hint text can enforce.
  #
  # Per AXIS rather than "derived_jurisdiction != jurisdiction", because a
  # package usually knows only one of the two: comparing whole rungs would go
  # silent the moment ANY axis is unrecorded, and with it would go the US-region
  # refusal that has been in place since long before the company seat existed.
  #
  # `self_hosted` is exempt — it is the third axis (§3.2) and makes no statement
  # the matrix could contradict.
  def jurisdiction_must_not_contradict_credentials
    return if jurisdiction.blank? || jurisdiction == SELF_HOSTED || referenced_credentials.empty?

    expected = JURISDICTION_MATRIX.key(jurisdiction)
    return if expected.nil?

    check_company_axis(expected.first)
    check_processing_axis(expected.last)
  end

  # FAIL CLOSED on an unstated region: `ai_credentials.region` is nullable and
  # its select carries a blank option, so "not stated" is the DEFAULT state of
  # any credential nobody explicitly classified — and treating it as compliant
  # let an eu_native package sit on a plain OpenAI credential with a clean
  # `valid?`. For a claim, the unknown case belongs with the violating one.
  def check_processing_axis(expected)
    actual = processing_axis
    return if actual == expected

    if expected
      offenders = referenced_credentials.reject { |credential| eu_processing_credential?(credential) }
      key = actual.nil? ? :unknown_region_conflict : :us_credential_conflict
      add_jurisdiction_error(key, offenders)
    else
      # An UNRECORDED region cannot prove an understatement. Fail-closed applies
      # to the EU claim above — "unknown" belongs with the violating case only
      # when the claim is the strict one. Here the claim is the conservative one,
      # and blocking it on nil accused the operator of the exact opposite of the
      # facts ("all credentials process inside the EU" about credentials that say
      # nothing at all). Since `region` is nullable with a blank select option,
      # that is the DEFAULT state of any credential nobody classified — so without
      # this guard no ③/④ package could be saved at all, while ① was already
      # refused by :unknown_region_conflict. The company axis has carried the same
      # guard from the start; this is the asymmetry closing, not a new leniency.
      return if actual.nil?

      add_jurisdiction_error(:eu_region_understated, referenced_credentials)
    end
  end

  # The company axis does NOT fail closed on an unrecorded seat, and the
  # asymmetry with the region above is deliberate (E12): `company_domicile` is
  # NULL on every row written before the column existed, so blocking on it would
  # invalidate every stored package at once. An unrecorded seat degrades to
  # #jurisdiction_warnings; a RECORDED one that contradicts the claim blocks —
  # which is the case §3.4 called "waved through as ①, without a warning".
  def check_company_axis(expected)
    actual = company_axis
    return if actual == expected || actual.nil?

    if expected
      add_jurisdiction_error(:foreign_company_conflict,
                             referenced_credentials.select { |credential| eu_company_credential?(credential) == false })
    else
      add_jurisdiction_error(:eu_company_understated, referenced_credentials)
    end
  end

  def add_jurisdiction_error(key, offenders)
    return if offenders.empty?

    errors.add(:jurisdiction, key, credentials: offenders.map(&:display_label).join(', '))
  end

  # Probing on every #valid? would put network I/O behind an innocent-looking
  # call; the same "only when the selection actually changes" idiom as
  # AiCredentialProviderRules.
  # Publishing counts as a change worth re-judging: `active` is the save that
  # puts the package in front of customers, and Google retires models between
  # one save and the next (the probe's own comment carries gemini-2.0-flash as
  # the standing example). Cheap now that the lookup is cache-only.
  def embedding_vertex_check_due?
    embedding_credential&.provider == FOREIGN_PROVIDER_IN_EU && embedding_model.present? &&
      (new_record? || will_save_change_to_embedding_credential_id? ||
        will_save_change_to_embedding_model? || will_save_change_to_active?)
  end

  def embedding_model_must_exist_in_vertex_region
    region = self.class.unavailable_vertex_region(credential: embedding_credential, model: embedding_model)
    return if region.nil?

    errors.add(:embedding_model, :vertex_model_unavailable, model: embedding_model, region: region)
  end
end
