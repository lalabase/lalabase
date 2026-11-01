# frozen_string_literal: true

# A named set of external documentation for a project, mirrored one-way from a
# folder in the connected git repository. The repo stays the single source of
# truth; Lalabase only holds a read-only synced copy.
# == Schema Information
#
# Table name: documentation_sets
#
#  id                    :uuid             not null, primary key
#  last_synced_at        :datetime
#  last_synced_commit    :string
#  name                  :string           not null
#  path_prefix           :string           default(".lalabase/doku/"), not null
#  sync_status           :string           default("never_synced"), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  organisation_id       :uuid             not null
#  project_id            :uuid             not null
#  project_repository_id :uuid             not null
#
# Indexes
#
#  idx_documentation_sets_project_name                (project_id,name,organisation_id) UNIQUE
#  index_documentation_sets_on_organisation_id        (organisation_id)
#  index_documentation_sets_on_project_id             (project_id)
#  index_documentation_sets_on_project_repository_id  (project_repository_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (project_repository_id => project_repositories.id)
#
class DocumentationSet < ApplicationRecord
  acts_as_tenant(:organisation)

  # Live sync state carried on the set itself (ProjectIndex live-state pattern).
  SYNC_STATUSES = %w[never_synced syncing ready failed].freeze

  belongs_to :project
  belongs_to :project_repository

  # delete_all instead of destroy: destroy would load every page (including its
  # markdown + rendered HTML bodies) into memory just to delete it — a
  # disconnect of a large set must not do that.
  #
  # Pages now OWN polymorphic embedding fragments (Slice 3) AND outgoing Reference
  # rows (Slice 4), and delete_all skips the page's dependent hooks — which would
  # leave orphans (a fragment the retriever keeps grounding on, or a stale link row).
  # So purge_page_dependents below deletes both in TWO queries BEFORE the pages
  # vanish, preserving the "don't load page bodies" property while still cleaning up.
  has_many :documentation_pages, dependent: :delete_all
  has_many :documentation_sync_runs, dependent: :delete_all
  has_many :documentation_set_views, dependent: :delete_all
  has_many :documentation_commits, dependent: :delete_all
  # destroy, not delete_all: the rows are small (no bodies), and only a destroy purges the
  # file. A disconnected set must not leave a private repository's images in the storage.
  has_many :documentation_assets, dependent: :destroy

  # prepend: true is LOAD-BEARING — it forces this to run BEFORE the association's
  # own dependent: :delete_all callback. Without it the pages would be gone by the
  # time we look them up, so the subquery would match nothing and the orphans leak.
  before_destroy :purge_page_dependents, prepend: true

  validates :name, presence: true, uniqueness: { scope: %i[project_id organisation_id] }
  validates :path_prefix, presence: true
  validates :sync_status, presence: true, inclusion: { in: SYNC_STATUSES }
  validate :repository_belongs_to_project
  validate :path_prefix_stays_inside_repository

  scope :ordered, -> { order(:name) }

  def syncing?
    sync_status == 'syncing'
  end

  def never_synced?
    sync_status == 'never_synced'
  end

  def ready?
    sync_status == 'ready'
  end

  def failed?
    sync_status == 'failed'
  end

  private

  # Delete the pages' polymorphic dependents (embedding fragments + outgoing
  # references) before the pages themselves are bulk-deleted (see the before_destroy
  # comment for the ordering contract). A subquery on the pages' ids keeps each to a
  # single DELETE without loading any page rows.
  def purge_page_dependents
    page_ids = documentation_pages.select(:id)
    DocumentationPage.purge_fragments_for(page_ids)
    DocumentationPage.purge_references_for(page_ids)
  end

  # The connected repository must belong to the same project as the set,
  # otherwise a set could pull docs from an unrelated project's repo.
  def repository_belongs_to_project
    return if project_repository.nil? || project_id.nil?
    return if project_repository.project_id == project_id

    errors.add(:project_repository, :mismatched_project)
  end

  # path_prefix is joined onto the clone directory by the sync job; an absolute
  # path ("/etc") or a "../" segment would make the job read files OUTSIDE the
  # cloned repository (Pathname#join swaps the base for absolute paths). First
  # defense layer — the job re-checks containment after joining, for rows that
  # were written past validations.
  def path_prefix_stays_inside_repository
    return if path_prefix.blank? # the presence validation reports that case

    return unless path_prefix.start_with?('/') || path_prefix.split('/').include?('..')

    errors.add(:path_prefix, :invalid)
  end
end
