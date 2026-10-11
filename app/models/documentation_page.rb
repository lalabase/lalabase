# frozen_string_literal: true

# A single markdown page inside a DocumentationSet, synced from one .md file in
# the source repo. Content is read-only in Lalabase (authored only in the repo).
# == Schema Information
#
# Table name: documentation_pages
#
#  id                       :uuid             not null, primary key
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  git_blob_sha             :string           not null
#  markdown_body            :text
#  path                     :string           not null
#  removed_at               :datetime
#  rendered_html            :text
#  title                    :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  documentation_set_id     :uuid             not null
#  organisation_id          :uuid             not null
#
# Indexes
#
#  idx_documentation_pages_set_path                   (documentation_set_id,path) UNIQUE
#  idx_on_documentation_set_id_removed_at_c6f42b1828  (documentation_set_id,removed_at)
#  index_documentation_pages_on_documentation_set_id  (documentation_set_id)
#  index_documentation_pages_on_organisation_id       (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (documentation_set_id => documentation_sets.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
# Why two content columns: markdown_body is the searchable SOURCE (and the
# input for later chat grounding, Slice 3); rendered_html is the sanitized
# display cache built once at sync time so browsing never re-renders markdown.
class DocumentationPage < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :documentation_set

  # Chat-grounding embeddings (Slice 3). dependent: :delete_all mirrors Ticket:
  # fragments have no callbacks of their own, so the cheaper bulk delete is safe.
  # NOTE this only covers a DIRECT page.destroy — the two bulk removal paths
  # (set delete_all cascade, sync soft-removal) bypass it and clean up via
  # .purge_fragments_for instead (see that method + DocumentationSet).
  has_many :fragments, as: :fragmentable, dependent: :delete_all

  # Outgoing links to knowledge objects (Slice 4), rebuilt each sync from the
  # lalabase:// links the renderer resolved (see DocumentationSyncJob). The page is
  # the Reference SOURCE, so on a DIRECT page.destroy its own links go too — the same
  # two bulk paths as fragments bypass this and use .purge_references_for instead.
  # (INCOMING links, i.e. another record pointing here, are not modelled: a doc page
  # is only ever a link source, never a target.)
  has_many :outgoing_references, class_name: 'Reference', as: :source, dependent: :destroy

  validates :path, presence: true, uniqueness: { scope: :documentation_set_id }
  validates :git_blob_sha, presence: true

  # Pages whose source file still exists in the repo (removed_at is nil).
  scope :present_pages, -> { where(removed_at: nil) }
  scope :ordered, -> { order(:path) }

  # Case-insensitive substring search over title and markdown source. Lives on
  # the model (not the controller) so it is unit-testable and reusable; LIKE
  # wildcards in user input are escaped so "100%" searches for a literal "%".
  scope :search_text, lambda { |query|
    escaped = sanitize_sql_like(query.to_s)
    where('documentation_pages.title ILIKE :q OR documentation_pages.markdown_body ILIKE :q', q: "%#{escaped}%")
  }

  def removed?
    removed_at.present?
  end

  # Plain-text projection consumed by EmbeddingProcessingService (its process
  # method early-returns unless the record responds to this AND it is present).
  # A method, not a stored column: markdown_body already holds the source, and
  # deriving on read keeps the two from drifting. Blank body → '' → the service
  # skips it (no fragments for an empty page).
  def plain_text_version
    Documentation::PlainTextRenderer.new.render(markdown_body)
  end

  # Bulk-delete the embedding fragments owned by the given pages. Fragments are
  # POLYMORPHIC → there is no DB foreign key, so the only thing that removes them
  # is a dependent hook on the owner. The sync job's two bulk paths bypass those
  # hooks on purpose (delete_all on set destroy, update_all on soft-removal), so
  # each MUST call this explicitly — otherwise the retriever keeps grounding chat
  # answers on docs whose source file is gone (deleted doc still surfacing).
  #
  # page_ids may be an Array or an ActiveRecord::Relation (→ subquery); an empty
  # Array yields WHERE 1=0 and deletes nothing, so no caller needs to guard.
  def self.purge_fragments_for(page_ids)
    Fragment.where(fragmentable_type: name, fragmentable_id: page_ids).delete_all
  end

  # Bulk-delete the OUTGOING Reference rows of the given pages — the source-side
  # twin of purge_fragments_for, for the same two bulk paths that bypass the
  # dependent: :destroy hook (set destroy delete_all, sync soft-removal update_all).
  # Deleting (not tombstoning): the page IS the source, and a source that no longer
  # exists has no links; tombstones are only for a vanished TARGET.
  #
  # page_ids may be an Array or a Relation; an empty Array yields WHERE 1=0.
  def self.purge_references_for(page_ids)
    Reference.where(source_type: name, source_id: page_ids).delete_all
  end
end
