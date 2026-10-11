# frozen_string_literal: true

namespace :gdpr do
  desc 'Remove PII (names, emails) from activities.parameters and notifications.payload'
  task cleanup_activity_pii: :environment do
    dry_run = ENV['DRY_RUN'] == 'true'
    puts dry_run ? '=== DRY RUN ===' : '=== LIVE RUN ==='

    activity_pii_keys = %w[assignee_name assignee_email unassignee_name unassignee_email subscriber_name subscriber_id]
    notification_pii_keys = %w[assignee_name assignee_email unassignee_name unassignee_email actor_name]

    # --- Activities ---
    puts "\n--- Activities ---"
    activity_count = 0
    skipped_count = 0

    Activity.where(action: %w[assigned unassigned subscriber_added subscriber_removed]).find_each do |activity|
      pii_present = activity_pii_keys.any? { |key| activity.parameters&.key?(key) }
      next unless pii_present

      # Safety: For assigned/unassigned, only clean if secondary_id is set
      if %w[assigned unassigned].include?(activity.action) && activity.secondary_id.blank?
        skipped_count += 1
        puts "  SKIP Activity #{activity.id} (#{activity.action}) — no secondary_id set"
        next
      end

      # For subscriber_added/removed, only clean if secondary_id is set
      if %w[subscriber_added subscriber_removed].include?(activity.action) && activity.secondary_id.blank?
        skipped_count += 1
        puts "  SKIP Activity #{activity.id} (#{activity.action}) — no secondary_id set"
        next
      end

      cleaned = activity.parameters.except(*activity_pii_keys)

      if dry_run
        removed = activity.parameters.slice(*activity_pii_keys)
        puts "  Would clean Activity #{activity.id} (#{activity.action}): remove #{removed.keys.join(', ')}"
      else
        activity.update_column(:parameters, cleaned)
      end
      activity_count += 1
    end
    puts "Activities: #{activity_count} cleaned, #{skipped_count} skipped"

    # --- Notifications ---
    puts "\n--- Notifications ---"
    notification_count = 0

    Notification.where(event_type: %w[ticket_assigned ticket_unassigned]).find_each do |notification|
      pii_present = notification_pii_keys.any? { |key| notification.payload&.key?(key) }
      next unless pii_present

      cleaned = notification.payload.except(*notification_pii_keys)

      if dry_run
        removed = notification.payload.slice(*notification_pii_keys)
        puts "  Would clean Notification #{notification.id} (#{notification.event_type}): remove #{removed.keys.join(', ')}"
      else
        notification.update_column(:payload, cleaned)
      end
      notification_count += 1
    end
    puts "Notifications: #{notification_count} cleaned"

    puts "\n=== Done ==="
  end
end
