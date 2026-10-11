# frozen_string_literal: true

module CodebaseImport
  # Value object for tag import results
  # Collects and structures all information about the tag import process
  class TagImportResult
    attr_reader :total_tags_found, :new_tags_created, :existing_tags_reused,
                :total_taggings_created, :errors, :processing_time

    def initialize(
      total_tags_found: 0,
      new_tags_created: 0,
      existing_tags_reused: 0,
      total_taggings_created: 0,
      errors: [],
      processing_time: nil
    )
      @total_tags_found = total_tags_found
      @new_tags_created = new_tags_created
      @existing_tags_reused = existing_tags_reused
      @total_taggings_created = total_taggings_created
      @errors = errors
      @processing_time = processing_time
    end

    def success?
      errors.empty?
    end

    def partial_success?
      total_tags_found > 0 && errors.any?
    end

    def failure?
      total_tags_found == 0 || (errors.any? && new_tags_created == 0 && total_taggings_created == 0)
    end

    def has_errors?
      errors.any?
    end

    # Converts the result into hash format for storage in the import_summary
    def to_summary_hash
      {
        total_tags_found: total_tags_found,
        new_tags_created: new_tags_created,
        existing_tags_reused: existing_tags_reused,
        total_taggings_created: total_taggings_created,
        success: success?,
        error_count: errors.size,
        errors: errors.first(5), # Only the first 5 errors for an overview
        processing_time_ms: processing_time&.in_milliseconds&.round(2)
      }
    end

    # Creates a result from a summary hash (for deserialization)
    def self.from_summary_hash(hash)
      return new unless hash.is_a?(Hash)

      new(
        total_tags_found: hash[:total_tags_found] || 0,
        new_tags_created: hash[:new_tags_created] || 0,
        existing_tags_reused: hash[:existing_tags_reused] || 0,
        total_taggings_created: hash[:total_taggings_created] || 0,
        errors: hash[:errors] || [],
        processing_time: hash[:processing_time_ms] ? (hash[:processing_time_ms] / 1000.0).seconds : nil
      )
    end

    # Combines this result with another one (for multi-phase imports)
    def merge(other_result)
      return self unless other_result.is_a?(TagImportResult)

      TagImportResult.new(
        total_tags_found: [total_tags_found, other_result.total_tags_found].max,
        new_tags_created: new_tags_created + other_result.new_tags_created,
        existing_tags_reused: existing_tags_reused + other_result.existing_tags_reused,
        total_taggings_created: total_taggings_created + other_result.total_taggings_created,
        errors: errors + other_result.errors,
        processing_time: combine_processing_times(processing_time, other_result.processing_time)
      )
    end

    # Returns a user-friendly summary
    def summary_message
      if success?
        message_parts = []
        message_parts << I18n.t('services.codebase_import.tag_import_result.new_tags_created', count: new_tags_created) if new_tags_created > 0
        message_parts << I18n.t('services.codebase_import.tag_import_result.existing_tags_reused', count: existing_tags_reused) if existing_tags_reused > 0
        message_parts << I18n.t('services.codebase_import.tag_import_result.taggings_created', count: total_taggings_created) if total_taggings_created > 0

        if message_parts.any?
          I18n.t('services.codebase_import.tag_import_result.success', details: message_parts.join(', '))
        else
          I18n.t('services.codebase_import.tag_import_result.no_tags_found')
        end
      elsif partial_success?
        I18n.t('services.codebase_import.tag_import_result.partial_success', count: errors.size)
      else
        I18n.t('services.codebase_import.tag_import_result.failed', count: errors.size)
      end
    end

    # Debug information for logging
    def debug_info
      {
        status: if success?
                  'success'
                else
                  (partial_success? ? 'partial' : 'failed')
                end,
        stats: {
          total_found: total_tags_found,
          new_created: new_tags_created,
          existing_reused: existing_tags_reused,
          taggings_created: total_taggings_created
        },
        errors: errors,
        processing_time: processing_time
      }
    end

    private

    def combine_processing_times(time1, time2)
      return time2 if time1.nil?
      return time1 if time2.nil?

      time1 + time2
    end
  end
end
