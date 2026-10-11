# frozen_string_literal: true

require 'rails_helper'

# Request spec (not controller spec) on purpose -- exercises the real admin path
# + the beuser session, matching spec/requests/admin/accounts_spec.rb.
#
# Guards the email dashboard's two stat panels ("Statusverteilung" +
# "Sendevolumen"). They used to be dead: the view rendered empty <canvas>
# elements that depended on Chart.js, which was never bundled into the asset
# pipeline -> permanently blank boxes, no JS error. The panels are now
# server-rendered bars derived from @stats[:by_status] / @stats[:by_day].
# These tests assert the rendered bars/values appear, so a regression back to
# empty canvases (or a broken aggregation) fails here instead of shipping blank.
#
# The full request path also runs under Prosopite (N+1 detection). The dashboard
# resolves organisation names via a preloaded hash (@organisation_names) because
# includes(:organisation) degrades to a per-row lazy load through the
# acts_as_tenant without-tenant admin stack -- these specs therefore also guard
# that the table stays N+1-free.
RSpec.describe 'Admin::EmailLogs dashboard charts', type: :request do
  let(:admin_beuser) { create(:beuser) } # factory: role 'admin', active
  let(:organisation) { create(:organisation) }

  def log_in_admin
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  describe 'GET /admin/email_logs' do
    context 'with email logs in the last 7 days' do
      before do
        # Factory creation makes per-record organisation validation queries
        # (belongs_to + acts_as_tenant on EmailLog/Notification) -- not a request
        # N+1, so pause Prosopite around setup (same pattern as ticket_spec.rb /
        # knowledge_search_query_spec.rb). The GET in each example is still scanned
        # and stays N+1-free thanks to @organisation_names.
        Prosopite.pause do
          ActsAsTenant.with_tenant(organisation) do
            create_list(:email_log, 3, :delivered, organisation: organisation)
            create(:email_log, :failed, organisation: organisation)
          end
        end
      end

      it 'server-renders the status distribution as bars, not a Chart.js canvas' do
        log_in_admin

        get admin_email_logs_path

        expect(response).to have_http_status(:ok)
        # Server-rendered bars carry an inline width; the dead canvas + its
        # window.Chart guard must be gone.
        expect(response.body).to include('style="width:')
        expect(response.body).not_to include('statusChartCanvas')
        expect(response.body).not_to include('window.Chart')
        # 3 delivered of 4 total -> 75.0% must be computed and rendered.
        expect(response.body).to include('75.0%')
      end

      it 'server-renders the daily volume as bars with a label for today' do
        log_in_admin

        get admin_email_logs_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('style="height:')
        expect(response.body).to include(Date.current.strftime('%d.%m'))
        expect(response.body).not_to include('volumeChartCanvas')
      end
    end

    context 'with no email logs in the window' do
      it 'shows the empty-state copy instead of a blank chart box' do
        log_in_admin

        get admin_email_logs_path # no logs -> no org N+1, scan normally

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(
          I18n.t('views.admin.email_logs.index.no_chart_data')
        )
      end
    end
  end
end
