# frozen_string_literal: true

# The EmailLog model tracks what happens to sent e-mails.
#
# PURPOSE:
# A log is created for every e-mail notification. This helps with debugging
# and ensures we can react automatically when e-mails bounce
# or users complain about spam.
#
# WHY BUILT THIS WAY:
# - Complete e-mail journey: queued → sent → delivered → opened → clicked
# - Bounce/complaint handling: after 3 bounces, e-mail notifications are automatically disabled
# - Protect sender reputation: important so our e-mails don't end up in the spam folder
# - Compliance: e-mail logs contain personal data, are cleaned up after 30 days
#
# EXAMPLE:
# E-mail is sent → status "sent", provider ID stored
# E-mail bounces → status "bounced", user automatically receives no more e-mails
# E-mail provider reports "opened" → status updated to "opened"
#
# ==================================================================================
# DASHBOARD FEATURE (September 2025)
# ==================================================================================
#
# OVERVIEW:
# Comprehensive e-mail monitoring dashboard for admin/backend with interactive features
# for monitoring and analyzing e-mail delivery in development, staging and production.
#
# CORE FUNCTIONS:
# 1. E-mail status tracking: complete lifecycle tracking (queued → sent → delivered → opened → clicked)
# 2. Error management: automatic detection and alerts for bounces/failures
# 3. Resend functionality: failed e-mails can be sent again
# 4. Performance metrics: delivery rate, open rate, click rate, bounce rate
# 5. Content storage: compressed HTML storage with Gzip for e-mail contents
# 6. Preview function: e-mail preview directly in the dashboard
#
# ARCHITECTURE DECISIONS:
#
# 1. DATA STORAGE:
#    - body_html_compressed: binary field with Gzip compression (saves ~70% storage)
#    - body_preview: text extract (500 characters) for a quick overview
#    - Separate timestamp fields (sent_at, delivered_at, etc.) for efficient queries
#    - Metadata as JSONB for flexible provider-specific data
#
# 2. PERFORMANCE OPTIMIZATIONS:
#    - Specific indexes for dashboard queries (organisation_id + sent_at, status + created_at)
#    - Eager loading scopes (with_notification, with_full_context) against N+1 queries
#    - Scope-based aggregations (by_status, by_day) for dashboard charts
#    - Table-prefixed queries (email_logs.created_at) for join compatibility
#
# 3. MULTI-TENANCY CONSIDERATIONS:
#    - acts_as_tenant for organisation isolation
#    - Unscoped access in the admin area for cross-tenant monitoring
#    - No direct user association to avoid tenant-context errors
#    - recipient_email as a denormalized field instead of a relation
#
# 4. RESEND MECHANISM:
#    - can_retry flag for retry control
#    - retry_count for limiting (max. 3 attempts)
#    - resent_from_id for an audit trail on resend attempts
#    - Transactional resend with a new log entry
#
# 5. DASHBOARD SCOPES:
#    - Time-based: today, this_week, this_month
#    - Aggregation: by_status, by_day, by_hour
#    - Performance: successful, failed_delivery
#    - Admin-optimized: for_admin_display with all relevant associations
#
# SECURITY CONSIDERATIONS:
# - No direct user data in logs (only e-mail address)
# - Automatic cleanup of old logs after 30/365 days
# - Admin-only access via a separate controller
# - CSRF protection for resend actions
#
# USAGE EXAMPLES:
#
#   # Dashboard statistics
#   EmailLog.this_week.by_status
#   # => { "sent" => 45, "delivered" => 38, "opened" => 12, "bounced" => 2 }
#
#   # Failed e-mails of the last 24h
#   EmailLog.failed_delivery.today.includes(:notification)
#
#   # Resend e-mail
#   log = EmailLog.find(id)
#   log.resend! if log.can_resend?
#
#   # Decompress HTML content
#   log.body_html # Automatic Gzip decompression
#
# WEBHOOK INTEGRATION (provider callbacks):
#   EmailLog.record_bounce!(message_id, bounce_data)
#   EmailLog.record_delivery!(message_id, delivery_data)
#   EmailLog.record_open!(message_id, open_data)
#   EmailLog.record_click!(message_id, click_data)

# == Schema Information
#
# Table name: email_logs
#
#  id                   :uuid             not null, primary key
#  body_html_compressed :binary
#  body_preview         :text
#  body_text            :text
#  bounce_type          :string
#  bounced_at           :datetime
#  can_retry            :boolean          default(TRUE)
#  click_count          :integer          default(0)
#  clicked_at           :datetime
#  delivered_at         :datetime
#  failed_at            :datetime
#  failure_reason       :text
#  lock_version         :integer          default(0), not null
#  metadata             :jsonb            not null
#  open_count           :integer          default(0)
#  opened_at            :datetime
#  recipient_email      :string
#  retry_count          :integer          default(0)
#  sent_at              :datetime
#  status               :integer          default("queued"), not null
#  subject              :string
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  notification_id      :uuid             not null
#  organisation_id      :uuid             not null
#  provider_message_id  :string
#  resent_from_id       :uuid
#
# Indexes
#
#  idx_email_logs_dashboard                         (organisation_id,status,created_at)
#  idx_email_logs_provider_msg                      (provider_message_id) WHERE (provider_message_id IS NOT NULL)
#  index_email_logs_on_notification_id_and_status   (notification_id,status)
#  index_email_logs_on_organisation_id_and_sent_at  (organisation_id,sent_at)
#  index_email_logs_on_organisation_id_and_status   (organisation_id,status)
#  index_email_logs_on_recipient_email              (recipient_email)
#  index_email_logs_on_resent_from_id               (resent_from_id)
#  index_email_logs_on_sent_at                      (sent_at)
#  index_email_logs_on_status_and_created_at        (status,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (notification_id => notifications.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (resent_from_id => email_logs.id)
#
class EmailLog < ApplicationRecord
  # Multi-tenancy - CRITICAL SECURITY FIX
  # EmailLogs must be isolated by organization to prevent data leaks
  # NOTE: In admin context, use EmailLog.unscoped to bypass tenant restrictions
  acts_as_tenant(:organisation)

  # Associations
  belongs_to :notification
  belongs_to :organisation

  # Enums
  enum :status, {
    queued: 0,
    sent: 1,
    delivered: 2,
    bounced: 3,
    complaint: 4,
    opened: 5,
    clicked: 6,
    failed: 7,
    deferred: 8,
    unsubscribed: 9
  }, prefix: true

  # Validations
  validates :notification, presence: true
  validates :status, presence: true

  # Scopes
  scope :successful, -> { where(status: %i[sent delivered opened clicked]) }
  scope :failed_delivery, -> { where(status: %i[bounced complaint failed]) }
  scope :recent, -> { order(created_at: :desc) }
  scope :for_notification, ->(notification) { where(notification: notification) }
  scope :within_days, ->(days) { where('email_logs.created_at > ?', days.days.ago) }

  # PERFORMANCE OPTIMIZED SCOPES - Include associations to prevent N+1
  scope :with_notification, -> { includes(:notification) }
  scope :with_notification_and_users, -> { includes(notification: %i[recipient actor]) }
  scope :with_full_context, -> { includes(notification: %i[recipient actor organisation]) }

  # Common query patterns with eager loading
  scope :for_webhook_processing, -> { joins(notification: :organisation).includes(notification: :organisation) }
  scope :for_admin_display, -> { includes(:notification, :organisation, notification: %i[recipient actor]) }

  # Dashboard scopes
  scope :today, -> { where('email_logs.created_at >= ?', Time.current.beginning_of_day) }
  scope :this_week, -> { where('email_logs.created_at >= ?', 1.week.ago) }
  scope :this_month, -> { where('email_logs.created_at >= ?', 1.month.ago) }
  scope :by_status, -> { group(:status).count }
  scope :by_day, -> { group('DATE(email_logs.created_at)').count }
  scope :by_hour, -> { group("DATE_TRUNC('hour', email_logs.created_at)").count }

  # Callbacks
  after_update_commit :handle_status_change, if: :saved_change_to_status?

  # Class methods
  class << self
    def create_for_notification!(notification, initial_status: :queued)
      return unless notification.channel_email?

      create!(
        notification: notification,
        organisation: notification.organisation,
        status: initial_status,
        metadata: {
          to: notification.recipient.email,
          subject: derive_subject_from_notification(notification),
          sent_at: nil,
          template: derive_template(notification)
        }
      )
    end

    def record_bounce!(message_id, bounce_data)
      return unless (log = find_by(provider_message_id: message_id))

      log.update!(
        status: :bounced,
        metadata: log.metadata.merge(
          'bounced_at' => Time.current.iso8601,
          'bounce_type' => bounce_data[:type],
          'bounce_reason' => bounce_data[:reason],
          'diagnostic_code' => bounce_data[:diagnostic_code]
        )
      )

      # Disable email notifications for hard bounces
      return unless bounce_data[:type] == 'Permanent'

      log.disable_all_email_notifications!
    end

    def record_delivery!(message_id, delivery_data = {})
      return unless (log = find_by(provider_message_id: message_id))

      log.update!(
        status: :delivered,
        metadata: log.metadata.merge(
          'delivered_at' => Time.current.iso8601,
          'delivery_time' => delivery_data[:delivery_time]
        )
      )
    end

    def record_complaint!(message_id, complaint_data)
      return unless (log = find_by(provider_message_id: message_id))

      log.update!(
        status: :complaint,
        metadata: log.metadata.merge(
          'complained_at' => Time.current.iso8601,
          'complaint_type' => complaint_data[:type],
          'user_agent' => complaint_data[:user_agent]
        )
      )

      # Disable email notifications for spam complaints
      log.disable_all_email_notifications!
    end

    def record_open!(message_id, open_data = {})
      return unless (log = find_by(provider_message_id: message_id))

      # Update status only if not already in a later stage
      return if log.status_clicked?

      log.update!(
        status: :opened,
        metadata: log.metadata.merge(
          'opened_at' => Time.current.iso8601,
          'ip_address' => open_data[:ip],
          'user_agent' => open_data[:user_agent]
        )
      )
    end

    def record_click!(message_id, click_data)
      return unless (log = find_by(provider_message_id: message_id))

      clicks = log.metadata['clicks'] || []
      clicks << {
        'url' => click_data[:url],
        'clicked_at' => Time.current.iso8601,
        'ip_address' => click_data[:ip],
        'user_agent' => click_data[:user_agent]
      }

      log.update!(
        status: :clicked,
        metadata: log.metadata.merge('clicks' => clicks)
      )
    end

    def cleanup_old_logs(days: 30)
      # Archive logs older than specified days (strip PII, keep audit trail)
      where('email_logs.created_at < ?', days.days.ago)
        .where('email_logs.created_at >= ?', 365.days.ago)
        .find_each do |log|
        log.update!(
          metadata: {
            'archived' => true,
            'original_status' => log.status,
            'archived_at' => Time.current.iso8601
          }
        )
      end

      # Hard delete very old logs
      where('email_logs.created_at < ?', 365.days.ago).destroy_all
    end

    private

    def derive_subject_from_notification(notification)
      # Extract a meaningful subject from the notification
      # This is a simplified version - in production, this would use I18n
      case notification.event_type
      when 'ticket_assigned'
        'Ticket assigned'
      when 'ticket_commented'
        'New comment'
      when 'ticket_status_changed'
        'Status changed'
      else
        notification.event_type.to_s.humanize
      end
    end

    def derive_template(notification)
      if notification.grouped?
        "#{notification.event_type}_grouped"
      else
        notification.event_type.to_s
      end
    end
  end

  # Instance methods
  def successful?
    status_sent? || status_opened? || status_clicked?
  end

  def failed?
    status_bounced? || status_complaint? || status_failed?
  end

  def engagement?
    status_opened? || status_clicked?
  end

  def engagement_time
    return unless metadata['opened_at'].present? && metadata['sent_at'].present?

    opened_time = Time.parse(metadata['opened_at'])
    sent_time = Time.parse(metadata['sent_at'])
    opened_time - sent_time
  end

  def disable_all_email_notifications!
    user = notification.recipient
    event_types = Notifications::Constants::VALID_EVENT_TYPES

    # Batch: load existing preferences in one query
    existing = NotificationPreference.where(
      user_id: user.id,
      organisation_id: nil,
      scope_type: nil,
      scope_id: nil,
      event_type: event_types,
      channel: 'email'
    ).index_by(&:event_type)

    # Bulk update existing preferences
    if existing.any?
      NotificationPreference.where(id: existing.values.map(&:id))
                            .update_all(enabled: false, frequency: 'never')
    end

    # Bulk insert missing preferences
    missing_types = event_types - existing.keys
    if missing_types.any?
      now = Time.current
      records = missing_types.map do |event_type|
        {
          user_id: user.id,
          organisation_id: nil,
          scope_type: nil,
          scope_id: nil,
          event_type: event_type,
          channel: 'email',
          enabled: false,
          frequency: 'never',
          created_at: now,
          updated_at: now
        }
      end
      NotificationPreference.insert_all(records)
    end

    Rails.logger.warn "Disabled ALL email notifications for user #{user.id} due to #{status}"
  end

  def disable_single_event_email_notification!
    user = notification.recipient

    NotificationPreference.find_or_create_by(
      user: user,
      organisation_id: nil,
      scope_type: nil,
      scope_id: nil,
      event_type: notification.event_type,
      channel: 'email'
    ).update!(
      enabled: false,
      frequency: 'never'
    )

    Rails.logger.warn "Disabled email notifications for user #{user.id} " \
                      "event_type=#{notification.event_type} due to #{status}"
  end

  # Instance methods for dashboard functionality

  # Safe decompression with memory limits
  MAX_DECOMPRESSED_SIZE = 10.megabytes
  MAX_COMPRESSED_SIZE = 5.megabytes

  # Compress HTML content to save space
  def body_html
    return nil unless body_html_compressed.present?

    safe_decompress(body_html_compressed)
  end

  def body_html=(html)
    return unless html.present?

    # Limit input size before compression
    if html.bytesize > MAX_DECOMPRESSED_SIZE
      Rails.logger.warn "HTML content too large (#{html.bytesize} bytes), truncating"
      html = html.truncate(MAX_DECOMPRESSED_SIZE)
    end

    self.body_html_compressed = ActiveSupport::Gzip.compress(html)
    self.body_preview = extract_preview_text(html)
  end

  # Check if email can be resent (only failed/bounced/deferred emails)
  def can_resend?
    return false unless can_retry
    return false unless status_failed? || status_bounced? || status_deferred?
    return false if retry_count && retry_count >= 3

    true
  end

  # Create a resend record with race condition protection
  def resend!
    return false unless can_resend?

    resent_log = nil

    transaction do
      # Acquire row-level lock to prevent concurrent resends
      lock!

      # Double-check after acquiring lock
      reload
      return false unless can_resend?

      # Check if already being resent (within last minute)
      recent_resend = self.class
                          .where(resent_from_id: id)
                          .where('created_at > ?', 1.minute.ago)
                          .exists?

      if recent_resend
        Rails.logger.warn "Recent resend already exists for EmailLog #{id}"
        return false
      end

      # Create new log entry for resend
      resent_log = self.class.create!(
        notification: notification,
        organisation: organisation,
        status: 'queued',
        recipient_email: recipient_email || metadata['to'],
        subject: subject || metadata['subject'],
        resent_from_id: id,
        metadata: metadata.merge(
          'resent_at' => Time.current.iso8601,
          'original_id' => id,
          'retry_attempt' => retry_count + 1
        )
      )

      # Update retry count with optimistic locking
      self.retry_count = (retry_count || 0) + 1
      save!
    end

    # Queue job AFTER transaction commits to ensure data is persisted
    EmailDeliveryJob.perform_later(notification.id) if resent_log && notification

    resent_log
  rescue ActiveRecord::StaleObjectError => e
    Rails.logger.warn "Concurrent resend attempted for EmailLog #{id}: #{e.message}"
    false
  rescue StandardError => e
    Rails.logger.error "Resend failed for EmailLog #{id}: #{e.message}"
    raise
  end

  # Dashboard display helpers
  def delivery_time
    return nil unless sent_at && delivered_at

    (delivered_at - sent_at).round(2)
  end

  def open_rate
    return 0 if open_count.to_i == 0

    100.0 # Opened at least once = 100%
  end

  def click_rate
    return 0 if click_count.to_i == 0 || open_count.to_i == 0

    (click_count.to_f / open_count * 100).round(2)
  end

  private

  # Safe bounded decompression with memory protection
  def safe_decompress(compressed_data, max_size: MAX_DECOMPRESSED_SIZE)
    return nil if compressed_data.nil?

    begin
      return nil if compressed_data.empty?
    rescue StandardError
      nil
    end # Handle encoding issues

    if compressed_data.bytesize > MAX_COMPRESSED_SIZE
      Rails.logger.warn "Compressed data exceeds limit: #{compressed_data.bytesize} bytes"
      return nil
    end

    begin
      io = StringIO.new(compressed_data)
      gz = Zlib::GzipReader.new(io)

      result = gz.read(max_size + 1)
      result = '' if result.nil? && gz.eof?

      if result && result.bytesize > max_size
        Rails.logger.warn "Decompressed data exceeds limit: #{result.bytesize} bytes"
        return nil
      end

      result
    rescue Zlib::GzipFile::Error, Zlib::DataError => e
      Rails.logger.warn "Gzip decompression failed: #{e.class.name} - #{e.message.truncate(200)}"
      nil
    rescue StandardError => e
      Rails.logger.error "Unexpected decompression error: #{e.class.name} - #{e.message.truncate(200)}"
      nil
    ensure
      begin
        gz&.close
      rescue StandardError
        nil
      end
      begin
        io&.close
      rescue StandardError
        nil
      end
    end
  end

  def extract_preview_text(html, max_length: 500)
    text = ActionView::Base.full_sanitizer.sanitize(html)
    text = text.gsub(/\s+/, ' ').strip
    text.truncate(max_length)
  end

  def handle_status_change
    if status_bounced? || status_complaint?
      check_and_disable_notifications
    elsif status_opened? || status_clicked?
      notification.mark_as_delivered! if notification.state_sent?
    end
  end

  def check_and_disable_notifications
    # Check if we should disable notifications based on bounce/complaint patterns
    recent_failures = EmailLog
                      .joins(:notification)
                      .where(notification: { recipient_id: notification.recipient_id })
                      .failed_delivery
                      .within_days(30)
                      .count

    # Disable if too many recent failures
    return unless recent_failures >= 3

    disable_all_email_notifications!
  end
end
