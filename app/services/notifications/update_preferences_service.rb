# frozen_string_literal: true

module Notifications
  # Service for the safe, performant update of NotificationPreferences
  #
  # Solves the following problems:
  # 1. SCOPE SAFETY: Prevents overwriting settings that were not in the form
  # 2. DATA INTEGRITY: Transactional updates with full rollback on errors
  # 3. PERFORMANCE: Batch-loading of existing preferences instead of N+1 database queries
  # 4. INPUT SAFETY: Validation and sanitization of all input parameters
  # 5. CONCURRENCY SAFETY: Retry logic for parallel updates to the same preferences
  # 6. SIMPLE FREQUENCY: Per event/channel only on (immediate) or off (never)
  #
  # USAGE:
  # result = Notifications::UpdatePreferencesService.call(
  #   user: current_user,
  #   organisation: current_organisation,
  #   preference_params: {
  #     'mention' => {
  #       'in_app' => { 'enabled' => '1' },
  #       'email' => { 'enabled' => '0' }
  #     }
  #   },
  #   submitted_scope: {
  #     events: ['mention', 'ticket_assigned'],
  #     channels: ['in_app', 'email']
  #   }
  # )
  #
  class UpdatePreferencesService
    include Notifications::Constants

    def self.call(user:, organisation:, preference_params:, submitted_scope: nil, full_matrix: false)
      new(user, organisation, preference_params, submitted_scope, full_matrix).call
    end

    def initialize(user, organisation, preference_params, submitted_scope = nil, full_matrix = false)
      @user = user
      @organisation = organisation
      @preference_params = preference_params || {}
      @submitted_scope = submitted_scope
      @full_matrix = full_matrix
      @updated_count = 0
      @created_count = 0
    end

    def call
      return { success: false, error: 'User required' } unless @user
      return { success: false, error: 'Organisation required' } unless @organisation

      NotificationPreference.transaction do
        submitted_events, submitted_channels = determine_submitted_scope

        # Batch-load existing preferences
        channels_for_prefetch = if @submitted_scope
                                  submitted_channels
                                else
                                  extract_channels_from_params(submitted_events)
                                end

        existing_preferences = preload_existing_preferences(submitted_events, channels_for_prefetch)

        upsert_payload = []

        submitted_events.each do |event_type|
          next unless valid_event_type?(event_type)

          # IMPORTANT: Always use ALL channels for every event,
          # otherwise unchecked checkboxes are not saved as false
          submitted_channels.each do |channel|
            next unless valid_channel?(channel)

            result = build_preference_data(event_type, channel, existing_preferences)
            upsert_payload << result if result
          end
        end

        upsert_payload.each { |attrs, existing_pref| save_with_retry(attrs, existing_pref) } if upsert_payload.any?

        Rails.logger.debug "NotificationPreferences updated: user=#{@user.id}, org=#{@organisation.id}, " \
                          "scope=#{submitted_events.size}x#{submitted_channels.size}, " \
                          "created=#{@created_count}, updated=#{@updated_count}"

        {
          success: true,
          updated_count: @updated_count,
          created_count: @created_count,
          total_processed: submitted_events.size * submitted_channels.size
        }
      end
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "NotificationPreferences update failed: #{e.message}"
      { success: false, error: e.message }
    rescue StandardError => e
      Rails.logger.error "NotificationPreferences service error: #{e.message}"
      { success: false, error: "Failed to update preferences: #{e.message}" }
    end

    private

    # Determines which event types and channels should actually be processed.
    # Prevents events from being overwritten that were not in the form.
    def determine_submitted_scope
      # PRIORITY 1: Explicitly set scope
      return [@submitted_scope[:events], @submitted_scope[:channels]] if @submitted_scope && @submitted_scope[:events] && @submitted_scope[:channels]

      # PRIORITY 2: Full-matrix mode (all events × channels)
      return [NotificationPreference.event_types.keys, NotificationPreference.channels.keys] if @full_matrix

      # PRIORITY 3: Derivation from the actual parameters
      submitted_events = @preference_params&.keys&.select { |k| valid_event_type?(k) } || []

      # IMPORTANT: Process all channels for submitted events,
      # so that unchecked checkboxes are saved as false
      submitted_channels = NotificationPreference.channels.keys

      [submitted_events, submitted_channels]
    end

    def extract_channels_from_params(submitted_events)
      channels = Set.new

      submitted_events.each do |event_type|
        event_data = @preference_params[event_type]
        next unless event_data.is_a?(Hash)

        event_data.keys.each do |channel|
          channels.add(channel) if valid_channel?(channel)
        end
      end

      channels.to_a
    end

    # Loads existing preferences in a single query (prevents N+1).
    def preload_existing_preferences(events, channels)
      return {} if events.empty? || channels.empty?

      @user.notification_preferences
           .where(
             organisation: @organisation,
             event_type: events,
             channel: channels,
             scope_type: nil,
             scope_id: nil
           )
           .index_by { |pref| [pref.event_type, pref.channel] }
    end

    def build_preference_data(event_type, channel, existing_preferences)
      raw_settings = @preference_params.dig(event_type, channel)
      existing_pref = existing_preferences[[event_type, channel]]

      # No settings submitted = checkbox unchecked → enabled: false
      raw_settings = { 'enabled' => '0' } if raw_settings.nil? || !raw_settings.is_a?(Hash) || raw_settings.empty?

      settings = sanitize_settings(raw_settings)

      if existing_pref
        return nil unless preference_changed?(existing_pref, settings)

        @updated_count += 1
      else
        @created_count += 1
      end

      attrs = {
        user_id: @user.id,
        organisation_id: @organisation.id,
        event_type: event_type,
        channel: channel,
        scope_type: nil,
        scope_id: nil,
        created_at: Time.current,
        updated_at: Time.current
      }.merge(settings)

      [attrs, existing_pref]
    end

    def sanitize_settings(raw_settings)
      enabled = sanitize_boolean(raw_settings['enabled'])

      {
        enabled: enabled,
        frequency: enabled ? 'immediate' : 'never'
      }
    end

    def sanitize_boolean(value)
      result = ActiveModel::Type::Boolean.new.cast(value)
      result.nil? ? false : result
    end

    def preference_changed?(existing_pref, new_settings)
      new_settings.any? do |key, value|
        existing_pref.public_send(key) != value
      end
    end

    def perform_bulk_upsert(payload)
      NotificationPreference.upsert_all(
        payload,
        unique_by: :idx_pref_uniqueness,
        update_only: %i[enabled frequency]
      )
    end

    def valid_event_type?(event_type)
      NotificationPreference.event_types.key?(event_type.to_s)
    end

    def valid_channel?(channel)
      NotificationPreference.channels.key?(channel.to_s)
    end

    # Retry logic for concurrency: when the same preference is saved simultaneously
    # a RecordNotUnique error can occur. Up to 2 retries with backoff.
    def save_with_retry(attrs, existing_pref = nil, max_retries = 2)
      retries = 0

      begin
        pref = if existing_pref
                 existing_pref
               elsif retries > 0
                 # On retry after RecordNotUnique, query DB to find the concurrent insert
                 NotificationPreference.find_or_initialize_by(
                   user_id: attrs[:user_id],
                   organisation_id: attrs[:organisation_id],
                   scope_type: attrs[:scope_type],
                   scope_id: attrs[:scope_id],
                   event_type: attrs[:event_type],
                   channel: attrs[:channel]
                 )
               else
                 # New record — preload_existing_preferences already confirmed it doesn't exist.
                 # Use .new to avoid an unnecessary DB query.
                 NotificationPreference.new(
                   user_id: attrs[:user_id],
                   organisation_id: attrs[:organisation_id],
                   scope_type: attrs[:scope_type],
                   scope_id: attrs[:scope_id],
                   event_type: attrs[:event_type],
                   channel: attrs[:channel]
                 )
               end

        # Set objects directly → prevents association-validation N+1
        if pref.new_record?
          pref.user = @user
          pref.organisation = @organisation
        end

        pref.assign_attributes(attrs.except(:user_id, :organisation_id, :scope_type, :scope_id, :event_type, :channel))
        pref.save! if pref.changed?
      rescue ActiveRecord::RecordNotUnique => e
        retries += 1

        if retries <= max_retries
          Rails.logger.warn "NotificationPreference RecordNotUnique, retrying #{retries}/#{max_retries}: #{attrs[:event_type]}+#{attrs[:channel]}"
          existing_pref = nil # Force re-query on retry
          sleep(0.01 * retries)
          retry
        else
          Rails.logger.error "NotificationPreference save failed after #{max_retries} retries: #{e.message}"
          raise e
        end
      end
    end
  end
end
