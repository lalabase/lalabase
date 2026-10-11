# frozen_string_literal: true

# == Schema Information
#
# Table name: code_symbols
#
#  id                    :uuid             not null, primary key
#  end_line              :integer          not null
#  file_path             :string           not null
#  language              :string           not null
#  metadata              :jsonb            not null
#  name                  :string           not null
#  qualified_name        :string           not null
#  signature             :text
#  start_line            :integer          not null
#  symbol_type           :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  organisation_id       :uuid             not null
#  project_repository_id :uuid             not null
#
# Indexes
#
#  idx_code_symbols_repo_path                   (project_repository_id,file_path)
#  idx_code_symbols_repo_qname                  (project_repository_id,qualified_name)
#  index_code_symbols_on_organisation_id        (organisation_id)
#  index_code_symbols_on_project_repository_id  (project_repository_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_repository_id => project_repositories.id)
#
class CodeSymbol < ApplicationRecord
  # class/module/method/constant come from the Ruby extractor; function/interface/
  # type/enum are emitted by the TypeScript extractor (M10). `symbol_type` is a
  # label the chat's LLM reads (Tools::GetSymbolDetails) — never a search filter
  # (semantic_search is pure vector cosine) — so this stays a plain string
  # whitelist: widening it needs no DB enum / migration, just honest labels.
  SYMBOL_TYPES = %w[class module method function constant interface type enum].freeze
  LANGUAGES    = %w[ruby javascript typescript python go rust].freeze

  acts_as_tenant(:organisation)

  belongs_to :project_repository

  # Sidecar embeddings (embedding v2, PR 2). dependent: :delete_all — cheap bulk
  # delete, fires on per-row #destroy (the ProjectRepository disconnect cascade).
  # IMPORTANT: does NOT fire when symbols die via a parent's delete_all — the two
  # repo re-index swaps (ProjectIndexerJob full replace, RepoReindexJob per-file)
  # purge the sidecar explicitly instead. Since PR 4b .semantic_search reads THESE
  # rows, so a leftover orphan cannot surface as a hit (M1 join). See
  # doc/embedding_v2_pr2_sidecar_plan.md §3.5.
  has_many :content_embeddings, as: :embeddable, dependent: :delete_all

  validates :symbol_type, presence: true, inclusion: { in: SYMBOL_TYPES }
  validates :language, inclusion: { in: LANGUAGES }, presence: true
  validates :name, :qualified_name, :file_path, presence: true
  validates :start_line, :end_line, presence: true,
                                    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate  :end_line_not_before_start_line

  scope :for_language, ->(lang) { where(language: lang) }
  scope :in_file,      ->(path) { where(file_path: path) }

  # Cosine nearest-neighbour search over signature embeddings, scoped to one
  # organisation + a set of repos. Kept as a thin delegator because it bundles the
  # repo scope for its TWO consumers (ProjectRag::Retriever#fetch_symbols and
  # Tools::SearchCodeSymbols) in ONE place.
  #
  # Since embedding v2 PR 4b the search runs over the content_embeddings sidecar via
  # Embeddings::NearestNeighbors, which owns the two pieces of coupling:
  #   - the metric (cosine) — idx_ce_code_symbol_1536_cos was built with
  #     vector_cosine_ops; any other metric silently bypasses the index,
  #   - organisation_id as explicit defense-in-depth on top of the repo filter,
  #     independent of acts_as_tenant's default scope.
  # Returns an Array (not a Relation): both consumers materialize immediately.
  def self.semantic_search(organisation:, repo_ids:, embedding:, limit:)
    Embeddings::NearestNeighbors.call(
      embeddable_type: 'CodeSymbol', organisation: organisation,
      query_vector: embedding, limit: limit,
      scope: where(project_repository_id: repo_ids)
    ).map(&:record)
  end

  private

  def end_line_not_before_start_line
    return if start_line.blank? || end_line.blank?
    return if end_line >= start_line

    errors.add(:end_line, :must_be_gte_start_line)
  end
end
