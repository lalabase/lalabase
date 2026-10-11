# frozen_string_literal: true

require 'rubygems/package'
require 'zip'

# Service for assigning uploads to tickets/posts
class CodebaseImport::UploadAssignmentService
  TIMEOUT_SECONDS = 600

  def initialize(organisation:, project:, user:, upload_import_file:)
    @organisation = organisation
    @project = project
    @user = user
    @upload_import_file = upload_import_file
    @assignment_results = []
    @errors = []
  end

  def call
    Rails.logger.info "[UPLOAD] Starting upload assignment for project #{@project.name}"
    if @upload_import_file.archive_file.present?
      Rails.logger.info "[UPLOAD] Upload file: #{@upload_import_file.id}, Archive size: #{@upload_import_file.archive_file.byte_size / 1.megabyte}MB"
    else
      Rails.logger.info "[UPLOAD] Upload file: #{@upload_import_file.id}, No archive file attached"
    end

    begin
      Timeout.timeout(TIMEOUT_SECONDS) do
        # 1. Parse uploads.xml
        Rails.logger.info '[UPLOAD] Step 1: Parsing uploads.xml'
        uploads_data = parse_uploads_xml
        Rails.logger.info "[UPLOAD] Found #{uploads_data.count} uploads in XML"

        # 2. Extract and process TAR file
        Rails.logger.info '[UPLOAD] Step 2: Extracting archive file'
        extract_tar_files

        # 3. Process only ticket-related uploads
        Rails.logger.info '[UPLOAD] Step 3: Filtering ticket uploads'
        ticket_uploads = filter_ticket_uploads(uploads_data)

        # 4. Assign uploads to tickets/posts
        Rails.logger.info '[UPLOAD] Step 4: Assigning uploads to tickets'
        assign_uploads_to_tickets(ticket_uploads)

        # 5. Cleanup temporary files
        Rails.logger.info '[UPLOAD] Step 5: Cleaning up temporary files'
        cleanup_temp_files

        Rails.logger.info '[UPLOAD] Assignment completed successfully'
        {
          success: true,
          processed_count: @assignment_results.count,
          errors: @errors,
          results: @assignment_results
        }
      end
    rescue Timeout::Error
      Rails.logger.error "[UPLOAD] Assignment timed out after #{TIMEOUT_SECONDS / 60} minutes"
      safe_cleanup
      {
        success: false,
        error: "Upload assignment timed out after #{TIMEOUT_SECONDS / 60} minutes",
        errors: @errors
      }
    rescue StandardError => e
      Rails.logger.error "[UPLOAD] Upload assignment failed: #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
      safe_cleanup
      {
        success: false,
        error: e.message,
        errors: @errors
      }
    end
  end

  private

  def parse_uploads_xml
    raise "Invalid file type: #{@upload_import_file.file_type}" unless @upload_import_file.file_type == 'uploads'

    @upload_import_file.parsed_data || []
  end

  def extract_tar_files
    return unless @upload_import_file.archive_file.present?

    # Create temporary directory
    @temp_dir = Rails.root.join('tmp', 'uploads_extract', SecureRandom.hex(8))
    FileUtils.mkdir_p(@temp_dir)

    # Determine the file format based on the file name
    if @upload_import_file.archive_file.filename.to_s.end_with?('.zip')
      extract_zip_streaming
    else
      extract_tar_streaming
    end
  end

  def extract_tar_streaming
    extract_root = File.expand_path(@temp_dir)
    # Use Active Storage for streaming access
    @upload_import_file.archive_file.open do |tar_file|
      Gem::Package::TarReader.new(tar_file) do |tar|
        tar.each do |entry|
          # Symlinks and hardlinks are not files: skipping them keeps a link from redirecting a later write
          next unless entry.file?

          # TarReader passes ../ and absolute names through unchanged
          file_path = safe_extract_target(entry.full_name, extract_root)
          next skip_escaping_entry(entry.full_name) unless file_path

          # Create directory structure
          FileUtils.mkdir_p(File.dirname(file_path))

          # Streaming write for large files
          File.open(file_path, 'wb') do |output_file|
            while (chunk = entry.read(8192)) # 8KB chunks
              output_file.write(chunk)
            end
          end
        end
      end
    end

    Rails.logger.debug "TAR extraction completed to #{@temp_dir}"
  rescue StandardError => e
    Rails.logger.error "TAR extraction failed: #{e.message}"
    raise "TAR extraction failed: #{e.message}"
  end

  def extract_zip_streaming
    Rails.logger.debug "[UPLOAD] Starting ZIP extraction, file size: #{@upload_import_file.archive_file.byte_size / 1.megabyte}MB"

    # Create temporary file for the ZIP to avoid memory issues
    temp_zip_path = Rails.root.join('tmp', "temp_zip_#{SecureRandom.hex(8)}.zip")

    begin
      # Stream ZIP to temporary file instead of loading into memory
      File.open(temp_zip_path, 'wb') do |temp_file|
        @upload_import_file.archive_file.open do |zip_stream|
          while (chunk = zip_stream.read(1.megabyte)) # 1MB chunks
            temp_file.write(chunk)
          end
        end
      end

      Rails.logger.debug "[UPLOAD] ZIP saved to temp file: #{temp_zip_path}"

      # Now process from file
      processed_count = 0
      extract_root = File.expand_path(@temp_dir)
      Zip::File.open(temp_zip_path) do |zip|
        total_entries = zip.size
        Rails.logger.debug "[UPLOAD] ZIP contains #{total_entries} entries"

        zip.each_with_index do |entry, index|
          next unless entry.file?

          # Log progress every 10 files
          Rails.logger.debug "[UPLOAD] Progress: #{index}/#{total_entries} files extracted" if index % 10 == 0

          target = safe_extract_target(entry.name, extract_root)
          next skip_escaping_entry(entry.name) unless target

          # Archives written without directory entries need the parent created by hand
          FileUtils.mkdir_p(File.dirname(target))

          # rubyzip joins destination_directory and entry.name itself and refuses
          # anything outside the root (its fix for CVE-2026-85396)
          entry.extract(destination_directory: extract_root) { true } # overwrite if exists
          processed_count += 1
        end
      end

      Rails.logger.debug "[UPLOAD] ZIP extraction completed: #{processed_count} files extracted to #{@temp_dir}"
    ensure
      # Cleanup temp ZIP file
      File.delete(temp_zip_path) if File.exist?(temp_zip_path)
    end
  rescue StandardError => e
    Rails.logger.error "[UPLOAD] ZIP extraction failed: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    raise "ZIP extraction failed: #{e.message}"
  end

  # Absolute path an entry would be written to, or nil when its name (../, an
  # absolute path, a sibling sharing the root prefix) leaves the extraction
  # root. The only guard for TAR; for ZIP deliberately the same check rubyzip
  # runs inside Entry#extract, guarding the mkdir_p that runs before it.
  def safe_extract_target(entry_name, extract_root)
    target = File.expand_path(File.join(extract_root, entry_name))
    target if target.start_with?("#{extract_root}#{File::SEPARATOR}")
  end

  def skip_escaping_entry(entry_name)
    Rails.logger.warn "[UPLOAD] Skipped #{entry_name}: it would land outside the extraction directory"
    @errors << { archive_entry: entry_name, error: 'Archive entry outside the extraction directory' }
  end

  def filter_ticket_uploads(uploads_data)
    uploads_data.select { |upload| upload[:linked_object_type] == CodebaseUpload::LINKED_TYPE_TICKET_UPDATE }
  end

  def assign_uploads_to_tickets(ticket_uploads)
    # Batch-fetch all ImportedObjects for the relevant update IDs to avoid per-item queries
    update_ids = ticket_uploads.map { |u| u[:linked_object_id].to_s }.uniq
    imported_objects = ImportedObject.where(importable_type: 'Post')
                                     .where(organisation_id: @organisation.id)
                                     .where("metadata->>'original_id' = ANY(ARRAY[?]::text[])", update_ids)
    @imported_objects_cache = imported_objects.index_by { |io| io.metadata['original_id'] }

    # Pre-load Post and Ticket associations to avoid N+1 from touch: true chain
    post_ids = imported_objects.map(&:importable_id).compact.uniq
    @cached_posts = Post.where(id: post_ids).includes(:ticket).index_by(&:id)

    # Skip touch: true cascades (PostDocument → Post → Ticket) during bulk import
    ActiveRecord::Base.no_touching do
      ticket_uploads.each_slice(10) do |batch|
        batch.each do |upload_data|
          process_single_upload(upload_data)
        rescue StandardError => e
          @errors << {
            upload_id: upload_data[:id],
            error: e.message
          }
          Rails.logger.error "[UPLOAD] Failed to process upload #{upload_data[:id]}: #{e.message}"
          Rails.logger.error e.backtrace.first(3).join("\n")
        end
      end
    end

    Rails.logger.info "[UPLOAD] Completed processing all uploads. Success: #{@assignment_results.count}, Errors: #{@errors.count}"
  end

  def process_single_upload(upload_data)
    # 1. Find the corresponding post/ticket update
    post = find_post_by_update_id(upload_data[:linked_object_id])

    unless post
      @errors << {
        upload_id: upload_data[:id],
        error: "Post not found for update ID: #{upload_data[:linked_object_id]}"
      }
      return
    end

    # 2. Find the physical file
    file_path = find_physical_file(upload_data[:identifier], upload_data[:file_name])

    unless file_path && File.exist?(file_path)
      @errors << {
        upload_id: upload_data[:id],
        error: "Physical file not found: #{upload_data[:file_name]}"
      }
      return
    end

    # 3. Attach file to post
    attach_file_to_post(post, file_path, upload_data[:file_name])

    # 4. Save upload tracking
    track_upload_assignment(upload_data)

    @assignment_results << {
      upload_id: upload_data[:id],
      post_id: post.id,
      ticket_id: post.ticket_id,
      file_name: upload_data[:file_name],
      success: true
    }
  end

  def find_post_by_update_id(update_id)
    # Use pre-fetched cache from assign_uploads_to_tickets, fall back to DB query
    imported_object = if @imported_objects_cache
                        @imported_objects_cache[update_id.to_s]
                      else
                        ImportedObject.where(importable_type: 'Post')
                                      .where(organisation_id: @organisation.id)
                                      .where(Arel.sql("metadata->>'original_id' = ?"), update_id.to_s)
                                      .first
                      end

    unless imported_object
      Rails.logger.warn "[UPLOAD] No imported_object found for update_id: #{update_id}"
      return nil
    end

    post = if @cached_posts
             @cached_posts[imported_object.importable_id] || imported_object.importable
           else
             imported_object.importable
           end

    if post&.ticket && post.ticket.project_id == @project.id
      post
    else
      Rails.logger.warn '[UPLOAD] Post found but belongs to different project or ticket missing'
      nil
    end
  end

  def find_physical_file(identifier, file_name)
    return nil if @temp_dir.nil?

    sanitized_identifier = File.basename(identifier.to_s)
    sanitized_name = File.basename(file_name.to_s)

    potential_path = @temp_dir.join(sanitized_identifier, sanitized_name)
    return potential_path if extracted_file?(potential_path)

    found_path = Dir.glob(@temp_dir.join('**', sanitized_name)).find { |path| extracted_file?(path) }
    Rails.logger.warn "[UPLOAD] File not found anywhere: #{sanitized_name}" unless found_path

    found_path
  end

  # A regular file inside the extraction directory. basename keeps '..' and '.'
  # as they are, so a sanitised name can still point at the directory itself or
  # one level above it; the check runs on the resolved path, not on the name.
  def extracted_file?(path)
    File.file?(path) && File.expand_path(path).start_with?("#{File.expand_path(@temp_dir)}#{File::SEPARATOR}")
  end

  def attach_file_to_post(post, file_path, original_filename)
    Rails.logger.debug "[UPLOAD] Attaching file #{original_filename} to post #{post.id}, size: #{File.size(file_path)}"

    # Create PostDocument
    post_document = post.post_documents.build(
      organisation: @organisation,
      create_embeddings: false # No embeddings for import attachments
    )

    # Read file content into memory to avoid stream issues
    file_content = File.read(file_path, mode: 'rb')
    file_io = StringIO.new(file_content)

    # Attach file using StringIO
    post_document.post_document_file.attach(
      io: file_io,
      filename: original_filename,
      content_type: Marcel::MimeType.for(file_path)
    )

    # Now save the post_document with attached file
    if post_document.save
      Rails.logger.debug "[UPLOAD] PostDocument saved successfully for post #{post.id}"
    else
      Rails.logger.error "[UPLOAD] Failed to save PostDocument: #{post_document.errors.full_messages.join(', ')}"
      raise "Failed to save PostDocument: #{post_document.errors.full_messages.join(', ')}"
    end
  rescue StandardError => e
    Rails.logger.error "[UPLOAD] Error attaching file: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    raise
  end

  def track_upload_assignment(upload_data)
    CodebaseUpload.create!(
      codebase_upload_id: upload_data[:id],
      file_name: upload_data[:file_name],
      linked_object_type: upload_data[:linked_object_type],
      linked_object_id: upload_data[:linked_object_id],
      organisation: @organisation,
      import_session_id: generate_assignment_session_id,
      processed: true
    )
  end

  def generate_assignment_session_id
    @assignment_session_id ||= "upload_assignment_#{@project.id}_#{Time.current.to_i}"
  end

  def safe_cleanup
    cleanup_temp_files
  rescue StandardError => e
    Rails.logger.warn "[UPLOAD] Cleanup failed: #{e.message}"
  end

  def cleanup_temp_files
    return unless @temp_dir && Dir.exist?(@temp_dir)

    FileUtils.rm_rf(@temp_dir)
  end
end
