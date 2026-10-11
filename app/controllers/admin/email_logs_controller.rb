# frozen_string_literal: true

require 'csv'

module Admin
  # ==================================================================================
  # EmailLogsController - Comprehensive Email Monitoring Dashboard
  # ==================================================================================
  #
  # PURPOSE:
  # Administrative dashboard for monitoring and managing all email activity
  # across all organisations. Provides insight into delivery performance,
  # error analysis and allows manual interventions when problems occur.
  #
  # MAIN FEATURES:
  # 1. Dashboard view with statistics and alerts
  # 2. Detailed email logs with filtering and search
  # 3. Email preview with full HTML content
  # 4. Resend functionality for failed emails
  # 5. CSV export for reporting and analysis
  # 6. JSON API for chart integration
  #
  # ARCHITECTURE CONSIDERATIONS:
  #
  # MULTI-TENANCY:
  # - Uses EmailLog.unscoped for cross-tenant access
  # - No ActsAsTenant in the admin area (global view)
  # - Avoids tenant-scoped associations (User, Notification)
  # - Uses denormalized fields (recipient_email instead of a User relation)
  #
  # PERFORMANCE OPTIMIZATIONS:
  # - Pagy for efficient pagination (instead of Kaminari)
  # - Minimal eager loading (only :notification, :organisation)
  # - Aggregated statistics with database-level queries
  # - Table-prefixed columns for unambiguous join queries
  #
  # FILTER STRATEGY:
  # - Status filter for targeted problem analysis
  # - Date range for time-based evaluations
  # - Organisation filter for tenant-specific views
  # - Full-text search in recipient_email for user support
  #
  # DASHBOARD METRICS:
  # - Delivery Rate: (delivered + opened + clicked) / total * 100
  # - Open Rate: (opened + clicked) / sent * 100
  # - Bounce Rate: bounced / sent * 100
  # - Top Organisations: sorted by email volume
  #
  # ERROR HANDLING:
  # - Graceful degradation when data is missing
  # - Division-by-zero protection in rate calculations
  # - Transactional resend with rollback on errors
  #
  # SECURITY CONSIDERATIONS:
  # - Admin-only access (ApplicationController check)
  # - CSRF protection for resend actions
  # - No direct exposure of user data
  # - CSV export without sensitive metadata
  #
  # UI/UX DECISIONS:
  # - Modal-based email preview (Ajax-loaded)
  # - Color-coded status badges (Tailwind classes)
  # - Real-time alerts for critical failures
  # - One-click resend with confirmation dialog
  #
  # INTEGRATION POINTS:
  # - Chart.js for visualizations (placeholder ready)
  # - Letter Opener for development preview
  # - Email provider webhooks (Postmark, SendGrid ready)
  # - Background jobs (Solid Queue) for resend
  #
  # USAGE EXAMPLES:
  #
  #   # Dashboard with filters
  #   GET /admin/email_logs?status=bounced&date_from=2025-01-01
  #
  #   # Email preview (Modal)
  #   GET /admin/email_logs/:id (Ajax)
  #
  #   # Resend a failed email
  #   POST /admin/email_logs/:id/resend
  #
  #   # CSV export
  #   GET /admin/email_logs/export?organisation_id=xxx
  #
  #   # Chart data API
  #   GET /admin/email_logs/stats?days=30
  #
  class EmailLogsController < ApplicationController
    include Pagy::Backend

    # Whitelists for filtering and validation
    ALLOWED_STATUSES = %w[queued sent delivered opened clicked bounced failed complaint deferred unsubscribed].freeze
    ALLOWED_SORT_COLUMNS = %w[created_at sent_at delivered_at status].freeze
    ALLOWED_SORT_DIRECTIONS = %w[asc desc].freeze
    MAX_SEARCH_LENGTH = 100
    MAX_DATE_RANGE_DAYS = 365

    # Disable tenant scoping for all actions in this controller
    # Admin area needs to see all email logs across all organizations
    around_action :without_tenant

    before_action :set_email_log, only: %i[show resend]
    before_action :validate_filter_params, only: %i[index export]

    def without_tenant(&block)
      ActsAsTenant.without_tenant(&block)
    end

    def index
      # Build scope without tenant restrictions (around_action handles tenant removal)
      email_logs_scope = build_filtered_scope

      # Use pagy with unscoped collection
      @pagy, @email_logs = pagy(email_logs_scope, items: 25)

      # Resolve organisation names for the table in a single query (see
      # #organisation_names_for -- includes(:organisation) N+1s under this stack).
      @organisation_names = organisation_names_for(@email_logs)

      # Dashboard statistics
      @stats = calculate_dashboard_stats

      # Recent failures for alerts (only recipient/status/time are rendered, so no
      # organisation eager-load -- it would lazy-load per row for the same reason).
      @recent_failures = EmailLog.unscoped
                                 .failed_delivery
                                 .order(created_at: :desc)
                                 .limit(10)

      respond_to do |format|
        format.html
        format.json { render json: @email_logs }
      end
    end

    private

    def build_filtered_scope
      # NOTE: do NOT includes(:organisation) here. Under the admin without-tenant
      # stack, acts_as_tenant degrades the :organisation eager-load to per-row
      # lazy loads (N+1). Organisation names are resolved via @organisation_names.
      scope = EmailLog.unscoped
                      .includes(:notification)

      # Apply filters with whitelist validation
      scope = apply_status_filter(scope)
      scope = apply_organisation_filter(scope)
      scope = apply_date_filters(scope)
      scope = apply_search_filter(scope)
      apply_sorting(scope)
    end

    # Resolve organisation names for a set of logs in ONE query. belongs_to
    # :organisation degrades to per-row lazy loads under the admin without-tenant
    # stack (acts_as_tenant defeats includes(:organisation)), so both the index
    # table and the CSV export look names up explicitly. Kept here so that
    # workaround lives in a single place.
    def organisation_names_for(logs)
      Organisation.where(id: logs.map(&:organisation_id).uniq).pluck(:id, :name).to_h
    end

    def apply_status_filter(scope)
      if params[:status].present? && ALLOWED_STATUSES.include?(params[:status])
        scope.where(status: params[:status])
      else
        scope
      end
    end

    def apply_organisation_filter(scope)
      if params[:organisation_id].present? && valid_uuid?(params[:organisation_id])
        scope.where(organisation_id: params[:organisation_id])
      else
        scope
      end
    end

    def apply_date_filters(scope)
      if params[:date_from].present?
        begin
          from_date = Date.parse(params[:date_from]).beginning_of_day
          # Prevent queries too far in the past
          from_date = [from_date, MAX_DATE_RANGE_DAYS.days.ago].max
          scope = scope.where('email_logs.created_at >= ?', from_date)
        rescue ArgumentError
          # Invalid date, ignore filter
        end
      end

      if params[:date_to].present?
        begin
          to_date = Date.parse(params[:date_to]).end_of_day
          # Prevent future dates
          to_date = [to_date, Time.current].min
          scope = scope.where('email_logs.created_at <= ?', to_date)
        rescue ArgumentError
          # Invalid date, ignore filter
        end
      end

      scope
    end

    def apply_search_filter(scope)
      if params[:search].present?
        # Sanitize and limit search term
        search_term = params[:search].to_s.strip[0...MAX_SEARCH_LENGTH]
        return scope if search_term.blank?

        # Use parameterized query with sanitized input
        sanitized = ActiveRecord::Base.sanitize_sql_like(search_term)
        scope.where('recipient_email ILIKE ?', "%#{sanitized}%")
      else
        scope
      end
    end

    def apply_sorting(scope)
      sort_column = params[:sort].presence_in(ALLOWED_SORT_COLUMNS) || 'created_at'
      sort_direction = params[:direction].presence_in(ALLOWED_SORT_DIRECTIONS) || 'desc'

      # Prefix with table name to avoid ambiguity
      scope.order("email_logs.#{sort_column} #{sort_direction}")
    end

    def validate_filter_params
      # Additional validation can be added here
      return unless params[:date_from].present? && params[:date_to].present?

      begin
        from = Date.parse(params[:date_from])
        to = Date.parse(params[:date_to])

        if (to - from).to_i > MAX_DATE_RANGE_DAYS
          flash.now[:warning] = t('flash.admin.email_logs.date_range_limited', days: MAX_DATE_RANGE_DAYS)
          params[:date_from] = MAX_DATE_RANGE_DAYS.days.ago.to_date.to_s
        end
      rescue ArgumentError
        # Invalid dates will be ignored
      end
    end

    def valid_uuid?(string)
      uuid_regex = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      string.match?(uuid_regex)
    end

    public

    def show
      @email_log = EmailLog.unscoped.find(params[:id])

      # Set strict Content Security Policy headers for email preview
      set_csp_headers_for_preview

      respond_to do |format|
        format.html { render layout: false }
        format.json do
          # Sanitize JSON output to prevent data leaks
          render json: @email_log.as_json(
            only: %i[id status subject recipient_email sent_at delivered_at],
            methods: [:body_preview]
          )
        end
      end
    end

    def resend
      @email_log = EmailLog.unscoped.find(params[:id])

      if @email_log.can_resend?
        new_log = @email_log.resend!

        respond_to do |format|
          format.html do
            flash[:success] = t('flash.admin.email_logs.resend_queued')
            redirect_to admin_email_logs_path
          end
          format.json { render json: { success: true, new_log_id: new_log.id } }
        end
      else
        respond_to do |format|
          format.html do
            flash[:error] = t('flash.admin.email_logs.resend_failed')
            redirect_to admin_email_logs_path
          end
          format.json { render json: { success: false, error: 'Email cannot be resent' }, status: :unprocessable_entity }
        end
      end
    end

    def stats
      # API endpoint for chart data
      scope = EmailLog.unscoped

      # Apply filters
      scope = scope.where(organisation_id: params[:organisation_id]) if params[:organisation_id].present?

      scope = if params[:days].present?
                scope.where('created_at >= ?', params[:days].to_i.days.ago)
              else
                scope.where('created_at >= ?', 30.days.ago)
              end

      stats = {
        by_status: scope.group(:status).count,
        by_day: scope.group('DATE(created_at)').count,
        by_hour: scope.where('created_at >= ?', 24.hours.ago)
                      .group("DATE_TRUNC('hour', created_at)")
                      .count,
        delivery_rate: calculate_delivery_rate(scope),
        open_rate: calculate_open_rate(scope),
        bounce_rate: calculate_bounce_rate(scope)
      }

      render json: stats
    end

    def export
      # Set headers for streaming
      headers['Content-Type'] = 'text/csv'
      headers['Content-Disposition'] = "attachment; filename=\"email_logs_#{Date.current}.csv\""
      headers['Cache-Control'] = 'no-cache'
      headers['X-Accel-Buffering'] = 'no' # Disable nginx buffering for streaming
      headers.delete('Content-Length') # Allow streaming

      # Export email logs as CSV using same filters as index
      scope = build_filtered_scope

      # Limit export size to prevent memory issues
      max_export_rows = 100_000
      row_count = 0

      # Stream CSV data
      self.response_body = Enumerator.new do |yielder|
        # Write headers
        yielder << CSV.generate_line(['ID', 'Organisation', 'Recipient', 'Subject', 'Status',
                                      'Sent At', 'Delivered At', 'Opened At', 'Bounced At',
                                      'Open Count', 'Click Count', 'Bounce Type', 'Failure Reason'])

        # The Enumerator body streams AFTER the around_action :without_tenant has
        # unwound, so re-establish the tenant-less context here. Otherwise the
        # deferred find_in_batches raises ActsAsTenant NoTenantSet (require_tenant
        # is process-wide). Admin CSV export is cross-org by design.
        ActsAsTenant.without_tenant do
          # Stream data in batches to control memory usage
          scope.find_in_batches(batch_size: 1000) do |batch|
            # Resolve org names once per batch (see #organisation_names_for) instead
            # of lazy-loading log.organisation per row -- that was a per-row N+1.
            org_names = organisation_names_for(batch)

            batch.each do |log|
              row_count += 1

              # Stop if we hit the limit
              if row_count > max_export_rows
                yielder << CSV.generate_line(['[Export limited to first 100,000 rows. Please use filters to narrow results.]'])
                break
              end

              # Generate CSV row with safe data extraction
              row = [
                log.id,
                org_names[log.organisation_id] || 'Unknown',
                log.recipient_email || 'N/A',
                (log.subject || log.metadata&.dig('subject') || 'No subject').truncate(100),
                log.status,
                log.sent_at&.strftime('%Y-%m-%d %H:%M:%S'),
                log.delivered_at&.strftime('%Y-%m-%d %H:%M:%S'),
                log.opened_at&.strftime('%Y-%m-%d %H:%M:%S'),
                log.bounced_at&.strftime('%Y-%m-%d %H:%M:%S'),
                log.open_count || 0,
                log.click_count || 0,
                log.bounce_type,
                log.failure_reason&.truncate(200)
              ]
              yielder << CSV.generate_line(Lalabase::CsvSafe.row(row))
            end

            break if row_count > max_export_rows
          end
        end
      end
    rescue Timeout::Error => e
      Rails.logger.error "CSV export timeout: #{e.message}"
      render json: { error: 'Export timeout. Please narrow your filters and try again.' }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error "CSV export error: #{e.message}"
      render json: { error: 'Export failed. Please try again with narrower filters.' }, status: :internal_server_error
    end

    private

    def set_email_log
      @email_log = EmailLog.unscoped.find(params[:id])
    end

    # Set strict CSP headers to prevent XSS in email previews
    def set_csp_headers_for_preview
      response.headers['Content-Security-Policy'] = [
        "default-src 'self'",
        "script-src 'none'", # No JavaScript allowed
        "style-src 'unsafe-inline' 'self'", # Allow inline styles (needed for emails)
        'img-src data: https: http:', # Allow images from data URIs and web
        "font-src 'self' data:", # Allow fonts
        "frame-src 'none'", # No frames
        "object-src 'none'", # No plugins
        "base-uri 'self'", # Prevent base tag injection
        "form-action 'none'", # No form submissions
        "frame-ancestors 'self'", # Only allow embedding in our own site
        'upgrade-insecure-requests' # Force HTTPS
      ].join('; ')

      # Additional security headers
      response.headers['X-Content-Type-Options'] = 'nosniff'
      response.headers['X-Frame-Options'] = 'SAMEORIGIN'
      response.headers['X-XSS-Protection'] = '1; mode=block'
      response.headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
    end

    def calculate_dashboard_stats
      # Only the two server-rendered charts consume @stats now (by_status, by_day).
      # The delivery/open/bounce rate tiles were removed: with plain-SMTP delivery
      # (no ESP webhooks) those statuses never advance past `sent`, so the rates were
      # structurally 0.0 % and misleading. The rate helpers live on for the `stats`
      # JSON endpoint.
      week_scope = EmailLog.unscoped.where('email_logs.created_at >= ?', 1.week.ago)

      {
        by_status: week_scope.group(:status).count,
        by_day: week_scope.group('DATE(email_logs.created_at)').count
      }
    end

    # Safe percentage calculation with nil and zero protection
    def safe_percentage(numerator, denominator)
      return 0.0 if denominator.nil? || denominator.zero? || numerator.nil?
      return 0.0 if numerator < 0 || denominator < 0

      result = (numerator.to_f / denominator) * 100
      result.finite? ? result.round(2) : 0.0
    end

    def calculate_delivery_rate(scope)
      total = scope.count
      delivered = scope.where(status: %i[delivered opened clicked]).count
      safe_percentage(delivered, total)
    end

    def calculate_open_rate(scope)
      sent = scope.where(status: %i[sent delivered opened clicked]).count
      opened = scope.where(status: %i[opened clicked]).count
      safe_percentage(opened, sent)
    end

    def calculate_bounce_rate(scope)
      sent = scope.where(status: %i[sent delivered bounced]).count
      bounced = scope.where(status: :bounced).count
      safe_percentage(bounced, sent)
    end
  end
end
