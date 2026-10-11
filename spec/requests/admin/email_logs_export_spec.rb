# frozen_string_literal: true

require 'rails_helper'

# Request spec (not controller spec) on purpose -- exercises the real admin path
# + the beuser session, matching spec/requests/admin/email_logs_charts_spec.rb.
#
# Guards the CSV export against an organisation N+1. The export streams rows via
# find_in_batches and previously read `log.organisation.name` per row. Because the
# admin controller runs under ActsAsTenant.without_tenant and the scope has no
# organisation preload, that lazy load fired one `SELECT ... FROM organisations`
# query PER ROW -- up to ~100k extra queries on a full export. The fix resolves
# names once per batch via #organisation_names_for (the same hash pattern the
# index table already uses).
#
# The regression is pinned two ways: (1) an explicit subscriber counts the
# organisation SELECTs during the export request and asserts the count stays a
# small constant instead of scaling with row count, and (2) the whole request
# path also runs under Prosopite (global scan in spec/support/prosopite.rb), so a
# per-row lazy load would raise there too.
RSpec.describe 'Admin::EmailLogs CSV export', type: :request do
  let(:admin_beuser) { create(:beuser) } # factory: role 'admin', active

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  # Count only SELECTs that read the organisations table during the block.
  def count_organisation_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      sql = payload[:sql]
      count += 1 if sql.match?(/FROM\s+"organisations"/i) && sql.match?(/\ASELECT/i)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe 'GET /admin/email_logs/export' do
    # Nine logs spread across THREE organisations. The pre-fix per-row lazy load
    # issued one organisations SELECT PER ROW (>= 9); the batched fix resolves
    # names once per find_in_batches batch. Factory creation itself makes
    # per-record validation queries, so pause Prosopite around setup (same
    # pattern as the charts spec).
    let(:log_count) { 9 }

    before do
      Prosopite.pause do
        3.times do
          org = create(:organisation)
          ActsAsTenant.with_tenant(org) do
            create_list(:email_log, 3, :delivered, organisation: org)
          end
        end
      end
    end

    it 'streams the CSV without an organisation N+1 (batched lookups, not per-row)' do
      log_in_admin

      org_queries = count_organisation_queries do
        get export_admin_email_logs_path
        # Force the streaming Enumerator body to be fully consumed within the
        # measured window (and within Prosopite's scan).
        response.body
      end

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/csv')
      # The guard is row-RELATIVE on purpose: the fix makes org lookups scale with
      # batches, not rows. All nine rows sit in one find_in_batches batch, so the
      # batched code issues one org SELECT per stream pass (the request harness may
      # replay the streaming body, hence not asserting == 1). The old per-row lazy
      # load issued >= log_count queries, so `< log_count` fails loudly on a
      # regression while staying robust to how often the harness enumerates.
      expect(org_queries).to be < log_count
    end

    it 'writes the real organisation name into each row, not a per-row lazy load' do
      org = create(:organisation, name: 'Acme Export GmbH')
      Prosopite.pause do
        ActsAsTenant.with_tenant(org) { create(:email_log, :bounced, organisation: org) }
      end

      log_in_admin
      get export_admin_email_logs_path(format: :csv)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Acme Export GmbH')
    end

    # A spreadsheet runs a cell that starts with "=" as a formula. The org name
    # comes from whoever created the organisation.
    it 'writes a formula-like organisation name as text' do
      org = create(:organisation, name: '=HYPERLINK("https://evil.example","x")')
      Prosopite.pause do
        ActsAsTenant.with_tenant(org) { create(:email_log, :bounced, organisation: org) }
      end

      log_in_admin
      get export_admin_email_logs_path(format: :csv)

      names = CSV.parse(response.body, headers: true).map { |row| row['Organisation'] }
      expect(names).to include(%('=HYPERLINK("https://evil.example","x")))
      expect(names).not_to include(org.name)
    end
  end
end
