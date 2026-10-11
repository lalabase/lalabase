# frozen_string_literal: true

require 'rails_helper'

# CRITICAL regression guard (Gespräche Slice 2, Iron Rule).
#
# Slice 2 rebuilds the time-list grouping from "group by ticket"
# (group_and_sort_by_ticket / _ticket_group) to a generic "group by subject"
# (Ticket OR Meeting). This spec freezes the pre-refactor behaviour for a
# TICKET-ONLY dataset: grouping, alphabetical sort, the no-subject group sorted
# last, billed sessions grouped under their ticket, and the group + grand totals.
#
# It was written and made green BEFORE the refactor and MUST stay green,
# unchanged, afterwards. If it turns red during the refactor the refactor is
# wrong, not this spec.
RSpec.describe 'Organisations::TimeSessions subject grouping (ticket-only regression)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }

  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  # Titles chosen so alphabetical order (alpha < zebra) differs from creation order.
  let(:alpha_ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user, title: 'Alpha-Ticket') }
  end
  let(:zebra_ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user, title: 'Zebra-Ticket') }
  end

  # Alpha group: one open (60) + one billed (90) session = 150 min → "02:30".
  let!(:alpha_open) do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, organisation: organisation, project: project, ticket: alpha_ticket,
                            creator: user, duration: 60, description: 'Alpha offen')
    end
  end
  let!(:alpha_billed) do
    ActsAsTenant.with_tenant(organisation) do
      ts = create(:time_session, organisation: organisation, project: project, ticket: alpha_ticket,
                                 creator: user, duration: 90, description: 'Alpha berechnet')
      ts.update!(billed: true)
      ts
    end
  end
  # Zebra group: single session (45) → "00:45".
  let!(:zebra_session) do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, organisation: organisation, project: project, ticket: zebra_ticket,
                            creator: user, duration: 45, description: 'Zebra Eintrag')
    end
  end
  # No-subject group: single session (30) → "00:30". Grand total 225 min → "03:45".
  let!(:no_subject_session) do
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, organisation: organisation, project: project, ticket: nil,
                            creator: user, duration: 30, description: 'Ohne Betreff Eintrag')
    end
  end

  let(:without_subject_label) { I18n.t('views.organisations.time_sessions.index_table.without_subject') }
  # turbo_stream render of the list frame (no application layout) — avoids the
  # full-page asset pipeline and mirrors the sibling index-table regression spec.
  let(:turbo_stream_headers) { { 'Accept' => 'text/vnd.turbo-stream.html' } }

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
    # Skip N+1 detection for these request examples WITHOUT leaking the scan:
    # stubbing Prosopite.finish left the scan open (Prosopite.scan is a no-op
    # while one is active), poisoning whichever spec file ran next.
    Prosopite.pause
  end

  after { Prosopite.resume }

  # All billing states + full date range so every session renders deterministically,
  # independent of the default "pending billing" filter and the default date window.
  def get_full_index
    get organisation_time_sessions_path(organisation),
        params: { project_id_filter: project.id, date_range: 'all', status_filters: %w[billed in_billing without_billing] },
        headers: turbo_stream_headers
  end

  it 'groups by ticket, sorts alphabetically and puts the no-subject group last' do
    get_full_index
    expect(response).to have_http_status(:ok)

    alpha_pos = response.body.index('Alpha-Ticket')
    zebra_pos = response.body.index('Zebra-Ticket')
    no_subject_pos = response.body.index(without_subject_label)

    expect(alpha_pos).to be_present
    expect(zebra_pos).to be_present
    expect(no_subject_pos).to be_present
    expect(alpha_pos).to be < zebra_pos
    expect(zebra_pos).to be < no_subject_pos
  end

  it 'keeps a billed session grouped under its ticket (not dropped, not anonymised)' do
    get_full_index
    expect(response.body).to include('Alpha berechnet')
  end

  it 'renders the aggregate group total (open + billed) for the multi-session ticket' do
    get_full_index
    # Alpha group total: 60 + 90 = 150 min.
    expect(response.body).to include(TimeSession.format_duration(150))
  end

  # ⚠️ Was "renders the grand total across all groups when show_sum=1", and it was
  # vacuum-green twice over. show_sum is gone (02.09.2026, the result row states
  # the sum on every render), and the assertion only asked whether "03:45"
  # appeared ANYWHERE in the body -- which it did, from the MONTH header, because
  # all four bookings sit in one month and the two figures happen to be equal.
  # A second month would have left the claim standing and the check passing.
  #
  # So: the whole PAGE, because the frame answer this file otherwise uses renders
  # the table alone and has no result row at all, and the row itself as the
  # oracle rather than the page's text.
  it 'renders the grand total across all groups, in the result row' do
    get organisation_time_sessions_path(organisation),
        params: { project_id_filter: project.id, date_range: 'all',
                  status_filters: %w[billed in_billing without_billing] }

    # 60 + 90 + 45 + 30 = 225 min.
    summary = Nokogiri::HTML(response.body).at_css('[data-result-summary]')
    expect(summary).to be_present
    expect(summary.text).to include(TimeSession.format_duration(225))
  end
end
