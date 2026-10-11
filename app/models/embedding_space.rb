# frozen_string_literal: true

# One vector space an organisation HOLDS: the provenance triple plus a snapshot of
# the credentials needed to SERVE it (embedding v2 PR 6a,
# doc/embedding_v2_pr6_retention_plan.md §4.1).
#
# Why the credential snapshot exists (review blocker B2, series plan §5.3): the org's
# embedding_* BYOK columns are single-valued. The moment an admin points them at a
# target endpoint, the still-ACTIVE old space loses the credentials it needs for its
# query embedding (B1) and for a roll-back delta reindex. A roll-back is an incident
# situation — the worst possible moment to re-enter access tokens.
#
# All three credential columns NULL means "resolve the system AiCredential", NOT "no
# credentials": copying the system credential in would freeze a rotating secret.
#
# WHICH system credential that is, is what ai_credential_id says (P0,
# doc/ki_pakete_plan.md §7b.2). NULL = resolve the provider's default by name (legacy
# rows and rows that never got a pin); SET = exactly this credential, and a pin that is
# gone or disabled is a LOUD error rather than a silent fall-back to the default — with
# two system credentials of one provider (Mistral FR / IONOS DE) that fall-back would
# serve this space the other one's key. The FK's ON DELETE nullify is the deliberate
# degradation: deleting a credential drops the pin back to name resolution.
#
# The pointer organisations.active_embedding_space_id selects which of an org's spaces
# SERVES; Actors::FlipEmbeddingModel is the only writer of that pointer.
# == Schema Information
#
# Table name: embedding_spaces
#
#  id                 :uuid             not null, primary key
#  access_token       :text
#  api_base           :string
#  embedding_dims     :integer          not null
#  embedding_model    :string           not null
#  embedding_provider :string           not null
#  retired_at         :datetime
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  ai_credential_id   :uuid
#  organisation_id    :uuid             not null
#  organization_id    :string
#
# Indexes
#
#  idx_embedding_spaces_unique_triple          (organisation_id,embedding_provider,embedding_model,embedding_dims) UNIQUE
#  index_embedding_spaces_on_ai_credential_id  (ai_credential_id)
#
# Foreign Keys
#
#  fk_rails_...  (ai_credential_id => ai_credentials.id) ON DELETE => nullify
#  fk_rails_...  (organisation_id => organisations.id) ON DELETE => cascade
#
class EmbeddingSpace < ApplicationRecord
  acts_as_tenant(:organisation)

  # Same shape as AiCredential#access_token / Organisation#embedding_access_token —
  # a BYOK token must never sit in the column as plain text (the Admin::AiCredential
  # finding). Pinned by a spec that reads the RAW column, not the attribute.
  encrypts :access_token, deterministic: false

  # Maintenance rewrite path for the encrypted column above (backfill + key
  # rotation): rake encryption:reencrypt_tokens → .reencrypt_tokens!
  include TokenReencryptable
  reencrypts_tokens :access_token

  validates :embedding_provider, :embedding_model, presence: true
  # Hard inclusion, deliberately WITHOUT the allow_nil that Organisation#embedding_dims
  # carries: that column means "unconfigured → system default", while a row here
  # describes an ALREADY RESOLVED space, and a space without a dimension does not exist.
  validates :embedding_dims, inclusion: { in: ::Organisation::SUPPORTED_DIMS,
                                          message: :supported_dimension }

  # Most recently RETIRED first, never-served LAST (embedding v2 PR 6b, sheet §4.2).
  # This is the order Embeddings::OrphanGc keeps an org's spaces by, and the NULLS LAST
  # half carries the weight: retired_at is NULL for a space that has never served — a
  # build abandoned before its flip — and such a space is no roll-back target, so it
  # must be collected BEFORE one that genuinely served and was displaced.
  #
  # Deliberately not created_at as the PRIMARY order. The two agree only while an org
  # switches straight ahead; after one roll-back they disagree, and created_at would
  # then keep the space that was rolled back FROM while deleting the one that was
  # rolled back TO — the roll-back net, collected in the exact situation it exists for.
  #
  # created_at/id ARE the tie-breakers (review A4): Postgres returns equal keys in
  # arbitrary order, and ties are not exotic — every space from before this column
  # existed sits at NULL, and two flips can share a second. Without the tie-break,
  # WHICH of the tied spaces survives the keep-selection changes from run to run.
  scope :by_retirement_recency, lambda {
    order(Arel.sql('retired_at DESC NULLS LAST'), created_at: :desc, id: :desc)
  }

  # The provenance triple in the EXACT shape Lalabase::Llm::Factory.embedding_space_for
  # returns and ContentEmbedding rows are stamped with, so alignment stays a plain Hash
  # comparison and no key can drift apart (same contract as
  # Embeddings::SpaceAlignment::Group#triple).
  def triple
    { embedding_provider: embedding_provider, embedding_model: embedding_model,
      embedding_dims: embedding_dims }
  end

  # The sidecar rows living in this space. NOT an association: content_embeddings has
  # no space_id — a row belongs to a space by carrying its TRIPLE, which is what keeps
  # the read seam's predicate and this relation the same question.
  def content_embeddings
    ContentEmbedding.where(organisation_id: organisation_id, **triple)
  end

  # True when this space is the one currently serving its org's queries. Read through
  # the org so there is ONE authority for "active" (the pointer column).
  def active?
    organisation.active_embedding_space_id == id
  end

  def label
    "#{embedding_provider}/#{embedding_model}/#{embedding_dims}"
  end
end
