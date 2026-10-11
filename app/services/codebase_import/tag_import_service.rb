# frozen_string_literal: true

module CodebaseImport
  # Service for importing tags from CodebaseHQ XML data
  # Implements bulk operations for optimal performance with large sets of tags
  class TagImportService
    include ActiveSupport::Benchmarkable

    attr_reader :organisation, :user, :import_session_id, :logger

    def initialize(organisation, user, import_session_id)
      @organisation = organisation
      @user = user
      @import_session_id = import_session_id
      @logger = Rails.logger

      # Performance caches
      @tag_cache = {}
      @newly_created_tags = Set.new
      @tag_assignment_cache = {}
      @all_tag_names = Set.new

      # Statistics
      @total_taggings_created = 0
      @errors = []
    end

    # Phase 1: Collect and create all tags in a bulk operation
    # Analyzes all tickets and creates missing tags in a single bulk insert
    def prepare_tags_from_tickets(tickets_data)
      start_time = Time.current

      ActsAsTenant.with_tenant(organisation) do
        logger.info "TagImportService: Starting tag preparation for #{tickets_data.size} tickets"

        collect_all_unique_tags(tickets_data)
        logger.info "TagImportService: Found #{@all_tag_names.size} unique tags"

        if @all_tag_names.any?
          create_missing_tags_bulk
          build_tag_cache
        end

        processing_time = Time.current - start_time

        result = TagImportResult.new(
          total_tags_found: @all_tag_names.size,
          new_tags_created: @newly_created_tags.size,
          existing_tags_reused: @all_tag_names.size - @newly_created_tags.size,
          processing_time: processing_time.seconds
        )

        logger.info "TagImportService: Tag preparation completed - #{result.summary_message}"
        result
      end
    rescue StandardError => e
      logger.error "TagImportService: Error during tag preparation: #{e.message}"
      @errors << "Tag preparation failed: #{e.message}"

      TagImportResult.new(
        total_tags_found: @all_tag_names.size,
        errors: @errors,
        processing_time: (Time.current - start_time).seconds
      )
    end

    # Phase 2: Assign tags to individual tickets (fast via cache)
    # Uses the built cache for O(1) tag lookup
    def assign_tags_to_ticket(ticket, tags_string)
      return unless tags_string.present?

      tag_names = parse_tag_string(tags_string)
      return if tag_names.empty?

      begin
        # Use cache for O(1) tag lookup
        tags = tag_names.filter_map { |name| @tag_cache[name] }

        logger.info "TagImportService: Processing tags for ticket ##{ticket.number}"
        logger.info "  Tag names from string: #{tag_names.inspect}"
        logger.info "  Tags found in cache: #{tags.size} (#{tags.map(&:name).join(', ')})"
        logger.info "  Tag cache keys: #{@tag_cache.keys.sort.join(', ')}"

        if tags.any?
          # Ensure we're in the correct tenant context
          ActsAsTenant.with_tenant(organisation) do
            # Create taggings directly using cached tag objects to avoid N+1 queries
            # (bypasses Taggable concern's process_tag_list_changes which does per-tag find_or_create)
            now = Time.current
            tagging_records = tags.map do |tag|
              { tag_id: tag.id, taggable_id: ticket.id, taggable_type: 'Ticket', created_at: now, updated_at: now }
            end
            Tagging.insert_all!(tagging_records)

            @total_taggings_created += tags.size

            # Cache for possible rollback tracking
            @tag_assignment_cache[ticket.id] = tag_names

            logger.info "TagImportService: Assigned #{tags.size} tags to ticket ##{ticket.number}"
          end
        else
          logger.warn "TagImportService: No tags found in cache for ticket ##{ticket.number} (searched for: #{tag_names.join(', ')})"
        end
      rescue StandardError => e
        error_msg = "Failed to assign tags to ticket ##{ticket.number}: #{e.message}"
        logger.error "TagImportService: #{error_msg}"
        logger.error "TagImportService: Backtrace: #{e.backtrace.first(5).join("\n")}"
        @errors << error_msg
      end
    end

    # Phase 3: Finalize import tracking for rollback capability
    # Creates ImportedObject records for all newly created tags
    def finalize_tag_tracking
      return TagImportResult.new if @newly_created_tags.empty?

      start_time = Time.current

      begin
        ActsAsTenant.with_tenant(organisation) do
          track_imported_tags_bulk
        end

        processing_time = Time.current - start_time

        final_result = TagImportResult.new(
          total_tags_found: @all_tag_names.size,
          new_tags_created: @newly_created_tags.size,
          existing_tags_reused: @all_tag_names.size - @newly_created_tags.size,
          total_taggings_created: @total_taggings_created,
          errors: @errors,
          processing_time: processing_time.seconds
        )

        logger.info "TagImportService: Finalization completed - #{final_result.summary_message}"
        final_result
      rescue StandardError => e
        error_msg = "Tag tracking finalization failed: #{e.message}"
        logger.error "TagImportService: #{error_msg}"
        @errors << error_msg

        TagImportResult.new(
          total_tags_found: @all_tag_names.size,
          new_tags_created: @newly_created_tags.size,
          existing_tags_reused: @all_tag_names.size - @newly_created_tags.size,
          total_taggings_created: @total_taggings_created,
          errors: @errors,
          processing_time: (Time.current - start_time).seconds
        )
      end
    end

    # Combines all three phases for simple single-call usage
    def import_tags_for_tickets(tickets_data)
      result = prepare_tags_from_tickets(tickets_data)

      # Only continue if tag preparation was successful
      if result.success? && @tag_cache.any?
        tickets_data.each do |ticket_data|
          next unless ticket_data[:tags].present?

          # The actual ticket object would have to be passed here
          # This method is mainly intended for testing
          logger.debug "TagImportService: Would assign tags '#{ticket_data[:tags]}' to ticket #{ticket_data[:id]}"
        end
      end

      finalize_tag_tracking
    end

    private

    # Collects all unique tag names from all tickets
    def collect_all_unique_tags(tickets_data)
      tickets_data.each do |ticket_data|
        next unless ticket_data[:tags].present?

        tag_names = parse_tag_string(ticket_data[:tags])
        @all_tag_names.merge(tag_names)
      end

      logger.debug "TagImportService: Collected #{@all_tag_names.size} unique tag names"
    end

    # Creates missing tags in a single bulk insert for optimal performance
    def create_missing_tags_bulk
      # Ensure we're in the correct tenant context
      ActsAsTenant.with_tenant(organisation) do
        logger.debug "TagImportService: Current tenant for bulk tag creation: #{ActsAsTenant.current_tenant&.id}"

        # Find already existing tags
        existing_tags = organisation.tags.where(name: @all_tag_names.to_a)
        existing_names = existing_tags.pluck(:name).to_set

        logger.debug "TagImportService: Found #{existing_names.size} existing tags: #{existing_names.to_a.join(', ')}"

        # Identify missing tags
        @newly_created_tags = @all_tag_names - existing_names

        return if @newly_created_tags.empty?

        logger.info "TagImportService: Creating #{@newly_created_tags.size} new tags: #{@newly_created_tags.to_a.join(', ')}"

        # Prepare data for the bulk insert
        new_tags_data = @newly_created_tags.map do |name|
          {
            name: name,
            organisation_id: organisation.id,
            created_at: Time.current,
            updated_at: Time.current
          }
        end

        # Use insert_all for optimal performance
        # Note: insert_all bypasses validations and callbacks, including acts_as_tenant
        Tag.insert_all!(new_tags_data)

        logger.info "TagImportService: Successfully created #{@newly_created_tags.size} new tags"

        # Verify tags were created
        created_tags = organisation.tags.where(name: @newly_created_tags.to_a)
        logger.debug "TagImportService: Verified #{created_tags.count} tags were created"
      end
    rescue StandardError => e
      logger.error "TagImportService: Bulk tag creation failed: #{e.message}"
      logger.error "TagImportService: Backtrace: #{e.backtrace.first(5).join("\n")}"
      @errors << "Bulk tag creation failed: #{e.message}"
      raise
    end

    # Builds a cache of all tags for fast O(1) access
    def build_tag_cache
      logger.debug 'TagImportService: Building tag cache'
      logger.debug "TagImportService: Looking for tags: #{@all_tag_names.to_a.join(', ')}"

      # Load all tags into the cache for O(1) access during tag assignment
      @tag_cache = organisation.tags
                               .where(name: @all_tag_names.to_a)
                               .index_by(&:name)

      logger.debug "TagImportService: Tag cache built with #{@tag_cache.size} entries"
      logger.debug "TagImportService: Cached tag names: #{@tag_cache.keys.join(', ')}"

      # Log any missing tags
      missing_tags = @all_tag_names - @tag_cache.keys.to_set
      return unless missing_tags.any?

      logger.warn "TagImportService: Tags not found in database after creation: #{missing_tags.to_a.join(', ')}"
    end

    # Creates ImportedObject records for all newly created tags (bulk insert)
    def track_imported_tags_bulk
      return if @newly_created_tags.empty?

      logger.info "TagImportService: Tracking #{@newly_created_tags.size} imported tags"

      # Fetch the actual tag objects that were created
      tags_to_track = organisation.tags.where(name: @newly_created_tags.to_a)

      # Prepare ImportedObject data
      imported_objects_data = tags_to_track.map do |tag|
        {
          organisation_id: organisation.id,
          importable_type: 'Tag',
          importable_id: tag.id,
          import_session_id: import_session_id,
          import_source: 'codebase_hq',
          imported_at: Time.current,
          created_at: Time.current,
          updated_at: Time.current,
          metadata: {
            original_name: tag.name,
            created_during_import: true,
            import_user_id: user.id
          }
        }
      end

      # Bulk insert for ImportedObject records
      ImportedObject.insert_all!(imported_objects_data)

      logger.info "TagImportService: Successfully tracked #{imported_objects_data.size} imported tags"
    rescue StandardError => e
      logger.error "TagImportService: Tag tracking failed: #{e.message}"
      @errors << "Tag tracking failed: #{e.message}"
      raise
    end

    # Parses a tag string from XML into normalized tag names
    # Implements the specified rules: whitespace-separated, case-insensitive
    def parse_tag_string(tags_string)
      return [] unless tags_string.present?

      tags_string.to_s
                 .split(/\s+/)           # Split on whitespace
                 .map(&:strip)           # Remove leading/trailing whitespace
                 .map(&:downcase)        # Case-insensitive (as specified)
                 .reject(&:blank?)       # Remove empty strings
                 .uniq                   # Remove duplicates
    end
  end
end
