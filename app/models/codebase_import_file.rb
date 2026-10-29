# frozen_string_literal: true

# == Schema Information
#
# Table name: codebase_import_files
#
#  id                      :uuid             not null, primary key
#  error_message           :text
#  file_content            :text
#  file_size               :integer
#  file_type               :string           not null
#  import_summary          :json
#  metadata                :json
#  original_filename       :string
#  processed_at            :datetime
#  processing_completed_at :datetime
#  processing_started_at   :datetime
#  status                  :string           default("uploaded")
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  organisation_id         :uuid             not null
#  project_id              :uuid
#  user_id                 :uuid             not null
#
# Indexes
#
#  index_codebase_import_files_on_organisation_id                 (organisation_id)
#  index_codebase_import_files_on_organisation_id_and_file_type   (organisation_id,file_type)
#  index_codebase_import_files_on_organisation_id_and_project_id  (organisation_id,project_id)
#  index_codebase_import_files_on_project_id                      (project_id)
#  index_codebase_import_files_on_status                          (status)
#  index_codebase_import_files_on_user_id                         (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
class CodebaseImportFile < ApplicationRecord
  acts_as_tenant :organisation

  belongs_to :organisation
  belongs_to :user
  belongs_to :project, optional: true

  has_one_attached :archive_file

  # Callbacks to clean up related data
  before_destroy :cleanup_imported_objects
  before_destroy :cleanup_import_mappings

  validates :file_type, presence: true, inclusion: { in: %w[users tickets time_tracking uploads] }
  validates :original_filename, presence: true
  validates :file_content, presence: true
  validates :file_size, presence: true, numericality: { greater_than: 0 }

  scope :users_files, -> { where(file_type: 'users') }
  scope :tickets_files, -> { where(file_type: 'tickets') }
  scope :by_status, ->(status) { where(status: status) }
  scope :general_imports, -> { where(project_id: nil) }
  scope :project_imports, -> { where.not(project_id: nil) }
  scope :for_project, ->(project) { where(project_id: project.id) }

  # File size limit (50MB for XML, 1GB for TAR/ZIP)
  MAX_FILE_SIZE = 50.megabytes
  MAX_TAR_FILE_SIZE = 1.gigabyte
  MAX_ZIP_FILE_SIZE = 1.gigabyte

  def self.valid_file_types
    %w[users tickets time_tracking uploads]
  end

  def self.general_file_types
    %w[users uploads]
  end

  def self.project_file_types
    %w[tickets time_tracking]
  end

  def general_import?
    self.class.general_file_types.include?(file_type)
  end

  def project_import?
    self.class.project_file_types.include?(file_type)
  end

  def parsed_data
    return nil if file_content.blank?

    case file_type
    when 'users'
      parse_users_xml
    when 'tickets'
      parse_tickets_xml
    when 'time_tracking'
      parse_time_tracking_xml
    when 'uploads'
      parse_uploads_xml
    end
  rescue StandardError => e
    Rails.logger.error "Error parsing XML for file #{id} (#{file_type}): #{e.message}"
    Rails.logger.error "XML content preview: #{file_content.truncate(500)}"
    Rails.logger.error "Backtrace: #{e.backtrace.first(5).join('\n')}"
    nil
  end

  def file_size_human
    ActionController::Base.helpers.number_to_human_size(file_size)
  end

  def uploaded_by_name
    user.display_name
  end

  # Progress tracking for import jobs
  def import_progress
    metadata.dig('progress') || {}
  end

  def import_progress_percentage
    import_progress.dig('percentage') || 0
  end

  def import_progress_current
    import_progress.dig('current') || 0
  end

  def import_progress_total
    import_progress.dig('total') || 0
  end

  # Tag-specific statistics
  def tag_statistics
    return {} unless import_summary.present?

    import_summary.dig('tags') || {}
  end

  def tags_created_count
    tag_statistics.dig('new_tags_created') || 0
  end

  def tags_reused_count
    tag_statistics.dig('existing_tags_reused') || 0
  end

  def total_tags_found
    tag_statistics.dig('total_tags_found') || 0
  end

  def taggings_created_count
    tag_statistics.dig('total_taggings_created') || 0
  end

  # Combined import statistics
  def processing_summary
    return {} unless import_summary.present?

    # Base statistics depending on file_type
    base_stats = case file_type
                 when 'tickets'
                   {
                     tickets_imported: import_summary.dig('imported_tickets') || 0,
                     tickets_failed: import_summary.dig('error_tickets') || 0,
                     total_tickets: import_summary.dig('total_tickets') || 0
                   }
                 when 'time_tracking'
                   {
                     time_sessions_imported: import_summary.dig('imported_time_sessions') || 0,
                     time_sessions_failed: import_summary.dig('error_time_sessions') || 0,
                     total_time_sessions: import_summary.dig('total_time_sessions') || 0
                   }
                 else
                   {}
                 end

    # Add tag statistics if available (only for tickets)
    if file_type == 'tickets' && tag_statistics.any?
      base_stats.merge!({
                          tags_created: tags_created_count,
                          tags_reused: tags_reused_count,
                          total_tags: total_tags_found,
                          taggings_created: taggings_created_count,
                          tag_import_success: tag_statistics.dig('success') || false
                        })
    end

    base_stats
  end

  # User-friendly status description
  def status_description
    case status
    when 'uploaded'
      'Bereit für Import'
    when 'processing'
      if import_progress_total > 0
        case file_type
        when 'tickets'
          "Importiere #{import_progress_current}/#{import_progress_total} Tickets (#{import_progress_percentage.round(1)}%)"
        when 'time_tracking'
          "Importiere #{import_progress_current}/#{import_progress_total} Zeit-Einträge (#{import_progress_percentage.round(1)}%)"
        else
          "Importiere #{import_progress_current}/#{import_progress_total} Einträge (#{import_progress_percentage.round(1)}%)"
        end
      else
        'Import läuft...'
      end
    when 'processed'
      summary = processing_summary

      case file_type
      when 'tickets'
        message_parts = ["#{summary[:tickets_imported]} Tickets importiert"]

        message_parts << "#{summary[:tags_created]} Tags erstellt" if summary[:tags_created] && summary[:tags_created] > 0

        message_parts << "#{summary[:tickets_failed]} #{I18n.t('models.codebase_import_file.errors_label')}" if summary[:tickets_failed] && summary[:tickets_failed] > 0
      when 'time_tracking'
        message_parts = ["#{summary[:time_sessions_imported]} Zeit-Einträge importiert"]

        message_parts << "#{summary[:time_sessions_failed]} #{I18n.t('models.codebase_import_file.errors_label')}" if summary[:time_sessions_failed] && summary[:time_sessions_failed] > 0
      else
        return 'Import abgeschlossen'
      end

      "Abgeschlossen: #{message_parts.join(', ')}"
    when 'failed'
      'Import fehlgeschlagen'
    when 'rolled_back'
      'Import rückgängig gemacht'
    else
      status.humanize
    end
  end

  # Checks whether tag import was enabled
  def includes_tags?
    tag_statistics.any? || import_progress.dig('tags').present?
  end

  private

  def parse_users_xml
    doc = Nokogiri::XML(file_content)
    users = []

    doc.xpath('//users-user').each do |user_node|
      user_data = {
        id: user_node.xpath('id').text,
        username: user_node.xpath('username').text.presence,
        email: user_node.xpath('email-address').text,
        full_name: user_node.xpath('full-name').text,
        role: {
          id: user_node.xpath('role/id').text,
          name: user_node.xpath('role/name').text,
          account_administrator: user_node.xpath('role/account-administrator').text == 'true'
        },
        company: {
          id: user_node.xpath('company/id').text.presence,
          name: user_node.xpath('company/name').text.presence
        }
      }
      users << user_data
    end

    users
  end

  def parse_tickets_xml
    doc = Nokogiri::XML(file_content)
    tickets = []

    doc.xpath('//tickets-ticket').each do |ticket_node|
      # Parse updates first to get the initial description
      updates = parse_ticket_updates(ticket_node)

      # Get description from the first update if it's marked as initial
      description_value = nil
      description_value = updates.first[:content] if updates.any? && updates.first[:initial]

      ticket_data = {
        id: ticket_node.xpath('id').text,
        project_id: ticket_node.xpath('project-id').text,
        number: ticket_node.xpath('number').text.to_i,
        subject: ticket_node.xpath('subject').text,
        description: description_value,
        summary: ticket_node.xpath('summary').text.presence,
        opened: ticket_node.xpath('opened').text == 'true',
        status_cache: ticket_node.xpath('status-cache').text,
        priority_cache: ticket_node.xpath('priority-cache').text,
        category_cache: ticket_node.xpath('category-cache').text,
        ticket_type_cache: ticket_node.xpath('ticket-type-cache').text,
        assignee_cache: ticket_node.xpath('assignee-cache').text.presence,
        reporter_cache: ticket_node.xpath('reporter-cache').text.presence,
        assignee_id: ticket_node.xpath('assignee-id').text.presence,
        reporter_id: ticket_node.xpath('reporter-id').text.presence,
        reporter_name: ticket_node.xpath('reporter-name').text.presence,
        reporter_email: ticket_node.xpath('reporter-email').text.presence,
        created_at: ticket_node.xpath('created-at').text,
        updated_at: ticket_node.xpath('updated-at').text,
        total_time_spent: ticket_node.xpath('total-time-spent').text.to_i,
        tags: ticket_node.xpath('tags').text.presence,
        updates: updates
      }
      tickets << ticket_data
    end

    tickets
  end

  def parse_ticket_updates(ticket_node)
    updates = []

    ticket_node.xpath('updates/update').each_with_index do |update_node, _index|
      update_data = {
        id: update_node.xpath('id').text,
        ticket_id: update_node.xpath('ticket-id').text,
        user_id: update_node.xpath('user-id').text.presence,
        content: update_node.xpath('content').text.presence,
        initial: update_node.xpath('initial').text == 'true',
        time_added: update_node.xpath('time-added').text.presence,
        created_at: update_node.xpath('created-at').text,
        updated_at: update_node.xpath('updated-at').text,
        author_name: update_node.xpath('author-name').text.presence,
        author_email: update_node.xpath('author-email').text.presence,
        ticket_changes: parse_ticket_changes(update_node)
      }

      updates << update_data
    end

    updates
  end

  def parse_ticket_changes(update_node)
    changes = {}

    update_node.xpath('ticket-changes').children.each do |change_node|
      next if change_node.text?

      change_name = change_node.name
      change_values = change_node.children.map(&:text).reject(&:blank?)
      changes[change_name] = change_values if change_values.any?
    end

    changes
  end

  def parse_time_tracking_xml
    doc = Nokogiri::XML(file_content)
    time_sessions = []

    doc.xpath('//time-sessions-session').each do |session_node|
      # Parse all fields with correct nil handling
      repository_id_node = session_node.xpath('repository-id').first
      repository_id = if repository_id_node&.attribute('nil')&.value == 'true'
                        nil
                      else
                        repository_id_node&.text&.presence
                      end

      commit_ref_node = session_node.xpath('commit-ref').first
      commit_ref = if commit_ref_node&.attribute('nil')&.value == 'true'
                     nil
                   else
                     commit_ref_node&.text&.presence
                   end

      time_session_data = {
        id: session_node.xpath('id').text,
        project_id: session_node.xpath('project-id').text,
        user_id: session_node.xpath('user-id').text,
        occurred_on: session_node.xpath('occurred-on').text,
        minutes: session_node.xpath('minutes').text.to_i,
        summary: session_node.xpath('summary').text.presence,
        ticket_id: session_node.xpath('ticket-id').text.presence,
        repository_id: repository_id,
        commit_ref: commit_ref,
        created_at: session_node.xpath('created-at').text,
        updated_at: session_node.xpath('updated-at').text,
        billed_group_id: session_node.xpath('billed-group-id').text.presence,
        cached_name: session_node.xpath('cached-name').text.presence,
        cached_email: session_node.xpath('cached-email').text.presence,
        ticket_update_id: session_node.xpath('ticket-update-id').text.presence
      }
      time_sessions << time_session_data
    end

    time_sessions
  end

  def parse_uploads_xml
    doc = Nokogiri::XML(file_content)
    uploads = []

    doc.xpath('//uploads/upload').each do |upload_node|
      # Parse user-id with nil attribute handling
      user_id_node = upload_node.xpath('user-id').first
      user_id = if user_id_node&.attribute('nil')&.value == 'true'
                  nil
                else
                  user_id_node&.text&.presence
                end

      # Parse objectstore-ids
      objectstore_ids = {}
      upload_node.xpath('objectstore-ids').children.each do |size_node|
        next if size_node.text?

        size_name = size_node.name
        size_id = size_node.xpath(size_name).text.strip.presence
        objectstore_ids[size_name] = size_id if size_id
      end

      upload_data = {
        id: upload_node.xpath('id').text.strip,
        account_id: upload_node.xpath('account-id').text.strip.presence,
        user_id: user_id,
        identifier: upload_node.xpath('identifier').text.strip.presence,
        file_name: upload_node.xpath('file-file-name').text.strip,
        file_content_type: upload_node.xpath('file-content-type').text.strip.presence,
        file_size: upload_node.xpath('file-file-size').text.strip.to_i,
        file_updated_at: upload_node.xpath('file-updated-at').text.strip.presence,
        linked_object_name: upload_node.xpath('linked-object-name').text.strip.presence,
        linked_object_type: upload_node.xpath('linked-object-type').text.strip,
        linked_object_id: upload_node.xpath('linked-object-id').text.strip,
        created_at: upload_node.xpath('created-at').text.strip.presence,
        updated_at: upload_node.xpath('updated-at').text.strip.presence,
        objectstore_ids: objectstore_ids
      }
      uploads << upload_data
    end

    uploads
  end

  def cleanup_imported_objects
    # Delete all ImportedObjects that belong to this import file
    imported_objects = ImportedObject.from_import_file(id)
    return unless imported_objects.any?

    Rails.logger.debug "CodebaseImportFile: Cleaning up #{imported_objects.count} imported objects for file #{id}"
    imported_objects.destroy_all
  end

  def cleanup_import_mappings
    # Delete all CodebaseImportMappings that belong to this import file
    # These are stored in the mapping_data
    mappings = CodebaseImportMapping.where("mapping_data ->> 'import_file_id' = ?", id.to_s)
    return unless mappings.any?

    Rails.logger.debug "CodebaseImportFile: Cleaning up #{mappings.count} import mappings for file #{id}"
    mappings.destroy_all
  end
end
