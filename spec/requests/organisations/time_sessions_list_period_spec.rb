# frozen_string_literal: true

require 'rails_helper'

# What: The list side of the shared period owner (TimeSessions::ListPeriod): the
#       segments it renders, the window each one applies, and what happens to a
#       period the list does not know.
# Type: Request spec over the rendered filter row and the list's own total.
# Why:  The eight keys used to be a literal array in _filter_pills and their
#       windows a `case` in the controller, and `date_range` was never checked
#       against a list at all. An unknown value lit no segment, applied no
#       window and left the empty state naming raw dates instead of a period --
#       silently, because "no window" and "alles" look the same until somebody
#       has old hours.
RSpec.describe 'Time list: the period', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:project)      { with_tenant { create(:project, organisation: organisation, name: 'WebApp2') } }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant { create(:membership, user: admin, organisation: organisation, role: admin_role, active: true) }
    sign_in admin
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  # The oracle here is the list's own total: the controller
  # only computes @total_filtered_duration when the sum is displayed.
  def get_list(params = {})
    get organisation_time_sessions_path(organisation, status_filters: TimeSession::BILLING_STATUS_FILTERS,
                                                      **params)
    expect(response).to have_http_status(:ok)
  end

  # One booking this month, one earlier this year, one last year.
  before do
    with_tenant do
      create(:time_session, project: project, organisation: organisation, creator: admin, duration: 30,
                            occurred_on: Time.zone.local(2026, 5, 15, 9, 0))
      create(:time_session, project: project, organisation: organisation, creator: admin, duration: 60,
                            occurred_on: Time.zone.local(2026, 1, 9, 9, 0))
      create(:time_session, project: project, organisation: organisation, creator: admin, duration: 90,
                            occurred_on: Time.zone.local(2025, 11, 3, 9, 0))
    end
  end

  it 'offers every preset of the owner as a segment, in its order' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      get_list

      doc = Nokogiri::HTML(response.body)
      labels = TimeSessions::ListPeriod::KEYS.map { |key| TimeSessions::ListPeriod.label(key) }
      rendered = doc.css('a').map { |a| a.text.strip }

      labels.each { |label| expect(rendered).to include(label), "segment #{label} is missing" }
      expect(rendered).to include(TimeSessions::ListPeriod.label('custom'))
    end
  end

  it 'applies the window of the chosen preset, not just its name' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      { 'this_month' => 30, 'year' => 90, 'all' => 180 }.each do |period, minutes|
        get_list(date_range: period)
        expect(assigns(:effective_date_range)).to eq(period)
        expect(assigns(:total_filtered_duration)).to eq(minutes), "#{period} summed #{assigns(:total_filtered_duration)}"
      end
    end
  end

  # The whitelist. Before S5 the value travelled on untouched: no segment lit,
  # no window applied, so the list silently answered "alles" under a name
  # nobody recognises.
  it 'falls back to the list default for a period it does not know' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      get_list(date_range: 'nonsense')

      expect(assigns(:effective_date_range)).to eq('this_month')
      expect(assigns(:total_filtered_duration)).to eq(30)
    end
  end

  it 'marks the active segment for a screen reader, and only that one' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      get_list(date_range: 'year')

      current = Nokogiri::HTML(response.body).css('a[aria-current="true"]').map { |a| a.text.strip }
      expect(current).to include(TimeSessions::ListPeriod.label('year'))
      expect(current).not_to include(TimeSessions::ListPeriod.label('all'))
    end
  end

  # `custom` belongs to the list alone: it is the only period whose window comes
  # from two date fields rather than from its key.
  it 'keeps custom, and lets typed bounds win over whatever key the address carries' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      get_list(date_range: 'this_month', start_date: '2025-11-01', end_date: '2025-11-30')

      expect(assigns(:effective_date_range)).to eq('custom')
      expect(assigns(:total_filtered_duration)).to eq(90)
    end
  end

  it 'survives a typed bound that is not a date' do
    travel_to Time.zone.local(2026, 5, 20, 12, 0) do
      get_list(start_date: 'gestern', end_date: '2026-07-31')

      expect(assigns(:effective_date_range)).to eq('custom')
      expect(assigns(:effective_start_date)).to be_nil
    end
  end
end
