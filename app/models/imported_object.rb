# frozen_string_literal: true

# == Schema Information
#
# Table name: imported_objects
#
#  id                :uuid             not null, primary key
#  import_source     :string           not null
#  importable_type   :string           not null
#  imported_at       :datetime         not null
#  metadata          :json
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  import_session_id :string           not null
#  importable_id     :uuid             not null
#  organisation_id   :uuid             not null
#
# Indexes
#
#  idx_on_organisation_id_import_session_id_2f43c61367            (organisation_id,import_session_id)
#  index_imported_objects_on_import_session_id_and_import_source  (import_session_id,import_source)
#  index_imported_objects_on_importable                           (importable_type,importable_id)
#  index_imported_objects_on_imported_at                          (imported_at)
#  index_imported_objects_on_organisation_id                      (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
class ImportedObject < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :organisation
  belongs_to :importable, polymorphic: true

  validates :import_session_id, presence: true
  validates :import_source, presence: true
  validates :imported_at, presence: true

  scope :by_session, ->(session_id) { where(import_session_id: session_id) }
  scope :by_source, ->(source) { where(import_source: source) }
  scope :by_type, ->(type) { where(importable_type: type) }
  scope :recent, -> { order(imported_at: :desc) }

  # Group imported objects by import session for easy management
  def self.sessions_summary(organisation_id = nil)
    scope = organisation_id ? where(organisation_id: organisation_id) : all

    scope.group(:import_session_id, :import_source, :imported_at)
         .group('DATE(imported_at)')
         .count
         .transform_keys do |key|
           session_id, source, imported_at, date = key
           {
             session_id: session_id,
             source: source,
             imported_at: imported_at,
             date: date
           }
         end
  end

  # Get summary for a specific import session
  def self.session_summary(session_id)
    where(import_session_id: session_id)
      .group(:importable_type)
      .count
  end

  # Get import file information for this object
  def import_file_info
    {
      file_id: metadata&.dig('import_file_id'),
      file_name: metadata&.dig('import_file_name'),
      original_id: metadata&.dig('original_id')
    }
  end

  # Find all objects imported from a specific file
  def self.from_import_file(file_id)
    where("metadata ->> 'import_file_id' = ?", file_id.to_s)
  end

  # Bulk delete all objects from an import session
  def self.delete_import_session(session_id, organisation_id = nil)
    scope = by_session(session_id)
    scope = scope.where(organisation_id: organisation_id) if organisation_id

    imported_objects = scope.includes(:importable)

    # Collect objects to delete (in reverse dependency order)
    tickets_to_delete = []
    posts_to_delete = []
    tags_to_delete = []
    activities_to_delete = []
    other_objects_to_delete = []

    imported_objects.find_each do |imported_object|
      case imported_object.importable_type
      when 'Post'
        posts_to_delete << imported_object.importable
      when 'Ticket'
        tickets_to_delete << imported_object.importable
      when 'Tag'
        tags_to_delete << imported_object.importable
      when 'Activity'
        activities_to_delete << imported_object.importable
      else
        other_objects_to_delete << imported_object.importable
      end
    end

    # Delete in correct order respecting dependencies
    tags_deleted_count = 0
    mappings_deleted_count = 0

    ActiveRecord::Base.transaction do
      # Phase 1: Delete activities first (they reference tickets and users)
      Rails.logger.debug "ImportedObject: Deleting #{activities_to_delete.count} activities"
      activities_to_delete.each(&:destroy!) if activities_to_delete.any?

      # Phase 2: Delete posts (they depend on tickets)
      Rails.logger.debug "ImportedObject: Deleting #{posts_to_delete.count} posts"
      posts_to_delete.each(&:destroy!) if posts_to_delete.any?

      # Phase 3: Delete other objects (except tags and tickets)
      Rails.logger.debug "ImportedObject: Deleting #{other_objects_to_delete.count} other objects"
      other_objects_to_delete.each(&:destroy!) if other_objects_to_delete.any?

      # Phase 4: Delete tickets (this will also remove associated taggings)
      Rails.logger.debug "ImportedObject: Deleting #{tickets_to_delete.count} tickets"
      tickets_to_delete.each(&:destroy!) if tickets_to_delete.any?

      # Phase 5: Smart tag deletion - only delete tags that are not used elsewhere
      tags_deleted_count = delete_tags_safely(tags_to_delete, session_id)

      # Phase 6: Delete CodebaseImportMappings for all deleted objects
      Rails.logger.debug 'ImportedObject: Deleting CodebaseImportMappings'
      deleted_ids = (posts_to_delete + tickets_to_delete + tags_to_delete + activities_to_delete + other_objects_to_delete).compact.map(&:id)
      if deleted_ids.any?
        mappings_deleted_count = CodebaseImportMapping.where(local_id: deleted_ids).delete_all
        Rails.logger.info "ImportedObject: Deleted #{mappings_deleted_count} CodebaseImportMappings"
      end

      # Phase 7: Delete the tracking records
      scope.delete_all
    end

    {
      posts_deleted: posts_to_delete.count,
      tickets_deleted: tickets_to_delete.count,
      tags_deleted: tags_deleted_count,
      activities_deleted: activities_to_delete.count,
      other_deleted: other_objects_to_delete.count,
      mappings_deleted: mappings_deleted_count,
      total_deleted: posts_to_delete.count + tickets_to_delete.count + tags_deleted_count + activities_to_delete.count + other_objects_to_delete.count
    }
  end

  # Intelligent tag deletion: deletes only tags that are used exclusively by imported objects
  def self.delete_tags_safely(tags_to_delete, session_id)
    return 0 if tags_to_delete.empty?

    Rails.logger.debug "ImportedObject: Analyzing #{tags_to_delete.count} tags for safe deletion"

    tags_deleted_count = 0

    tags_to_delete.compact.each do |tag|
      next unless tag&.persisted?

      begin
        # Check whether the tag is used by objects outside this import
        non_import_usage_exists = tag_used_outside_import?(tag, session_id)

        if non_import_usage_exists
          Rails.logger.debug "ImportedObject: Keeping tag '#{tag.name}' - used by non-imported objects"
        else
          Rails.logger.debug "ImportedObject: Deleting tag '#{tag.name}' - only used by imported objects"
          tag.destroy!
          tags_deleted_count += 1
        end
      rescue StandardError => e
        Rails.logger.error "ImportedObject: Error processing tag '#{tag&.name}': #{e.message}"
        # An error on one tag should not stop the rollback
      end
    end

    Rails.logger.info "ImportedObject: Successfully deleted #{tags_deleted_count} tags"
    tags_deleted_count
  end

  # Checks whether a tag is used by objects outside the current import
  def self.tag_used_outside_import?(tag, session_id)
    tag.taggings.joins(
      sanitize_sql_array([
                           "LEFT JOIN imported_objects io ON io.importable_id = taggings.taggable_id
         AND io.importable_type = taggings.taggable_type
         AND io.import_session_id = ?", session_id
                         ])
    ).where('io.id IS NULL').exists?
  end
end
