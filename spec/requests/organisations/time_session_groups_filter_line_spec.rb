# frozen_string_literal: true

require 'rails_helper'

# The filter LINE of the billings list (P2 of
# doc/abrechnungen_filterzeile_und_tabelle_plan.md), the time list's language on
# the sibling tab: three choice pills (period, status, project) from the shared
# partial, option counts as option sub-text (D-C, counted under the OTHER
# filters - the F4 rule), the search in the panel, the reset to the bare route,
# and the two frame-dependent regions that must travel INSIDE the frame answer.
#
# The oracle is the state a pill declares and the address its options lead to,
# not the pill's text - the same reasoning as the time list's filter line spec.
RSpec.describe 'Billings list: the filter line', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role)   { create(:admin_role, organisation: organisation) }
  let(:admin)        { create(:user) }
  let(:project_a) { with_tenant { create(:project, organisation: organisation, name: 'Muster Portal') } }
  let(:project_b) { with_tenant { create(:project, organisation: organisation, name: 'WebApp2') } }

  before do
    ActsAsTenant.current_tenant = organisation
    with_tenant { create(:membership, user: admin, organisation: organisation, role: admin_role, active: true) }
    sign_in admin
  end

  after { ActsAsTenant.current_tenant = nil }

  def with_tenant(&block)
    ActsAsTenant.with_tenant(organisation, &block)
  end

  def create_group(project: nil, sessions: 1, minutes: 60, **attrs)
    with_tenant do
      group = create(:time_session_group, organisation: organisation, creator: admin, **attrs)
      sessions.times do
        create(:time_session, time_session_group: group, project: project,
                              organisation: organisation, creator: admin, duration: minutes)
      end
      group
    end
  end

  def get_list(**params)
    get organisation_time_session_groups_path(organisation, **params)
    expect(response).to have_http_status(:ok)
  end

  def doc = Nokogiri::HTML(response.body)

  def pill(key, scope = doc) = scope.at_css(%([data-filter-pill="#{key}"]))

  def options(key, scope = doc)
    pill(key, scope)&.css('a[data-filter-pill-option]') || []
  end

  describe 'the three choices' do
    let!(:open_a) { create_group(project: project_a) }
    let!(:open_b) { create_group(project: project_b) }
    let!(:billed_b) { create_group(project: project_b, billed: true, invoice_number: 'RE-2026-118') }

    it 'offers period and project pills plus the status row, with real words' do
      get_list

      keys = doc.css('[data-filter-pill]').map { |node| node['data-filter-pill'] }
      expect(keys).to eq(%w[period project])
      expect(doc.css('[data-status-box]').map { |node| node['data-status-box'] })
        .to eq(%w[unbilled billed])

      # The whole page, not one label: the first version of this line resolved
      # its keys under the template's lazy scope (no views prefix), rendered
      # "translation missing" spans - and this file stayed green because it
      # only read counts and data attributes. Never again, page-wide.
      expect(response.body).not_to include('translation_missing')

      unbilled_word = doc.at_css('[data-status-box="unbilled"]').css('span')[1].text.strip
      expect(unbilled_word).to eq(I18n.t('views.time_sessions.billing_status.in_billing'))
    end

    it 'carries the count beside every status box, and on every project option' do
      get_list

      figures = doc.css('[data-status-box]').to_h do |box|
        [box['data-status-box'], box.css('span').last.text.strip]
      end
      expect(figures).to eq('unbilled' => '2', 'billed' => '1')

      project_counts = options(:project).to_h do |o|
        [o.css('span').first.text.strip, o.css('span').last.text.strip]
      end
      expect(project_counts['Muster Portal']).to eq('1')
      expect(project_counts['WebApp2']).to eq('2')
    end

    it 'counts each control under the OTHER filters (F4)' do
      get_list(billing_status: 'billed')

      # The project counts answer "billed billings per project": only WebApp2
      # has one. The status figures ignore the status filter itself.
      project_counts = options(:project).to_h do |o|
        [o.css('span').first.text.strip, o.css('span').last.text.strip]
      end
      expect(project_counts['WebApp2']).to eq('1')
      expect(project_counts['Muster Portal']).to eq('0')

      figures = doc.css('[data-status-box]').to_h do |box|
        [box['data-status-box'], box.css('span').last.text.strip]
      end
      expect(figures).to eq('unbilled' => '2', 'billed' => '1')
    end

    it 'toggles a status box like the time list, absent set meaning both' do
      get_list(billing_states: ['unbilled'])

      unbilled = doc.at_css('[data-status-box="unbilled"]')
      billed = doc.at_css('[data-status-box="billed"]')
      expect(unbilled['data-status-state']).to eq('on')
      expect(billed['data-status-state']).to eq('off')

      # Turning billed ON adds it to the set; turning unbilled OFF clears the
      # parameter, and the absent parameter is the default: both boxes on.
      expect(billed['href']).to include('billing_states%5B%5D=unbilled')
      expect(billed['href']).to include('billing_states%5B%5D=billed')
      expect(unbilled['href']).not_to include('billing_states')
      expect(unbilled['href']).not_to include('billing_status')
    end

    it 'keeps the period always set and never clearable' do
      get_list

      expect(pill(:period)['data-filter-pill-state']).to eq('set')
      expect(pill(:period).at_css('summary a')).to be_nil
    end

    it 'aims a period preset at the billings route with the bounds cleared' do
      get_list(start_date: '2025-06-01', end_date: '2025-06-30')

      year_option = options(:period).find { |o| o['data-filter-pill-option'] == 'year' }
      expect(year_option['href']).to include(organisation_time_session_groups_path(organisation))
      expect(year_option['href']).to include('date_range=year')
      expect(year_option['href']).not_to include('start_date')
    end
  end

  describe 'the search and the reset' do
    let!(:group) { create_group(project: project_a, name: '08-2026-pselector') }

    it 'offers no reset on the bare, unnarrowed page' do
      get_list

      expect(doc.at_css('#billing_filter_reset a')).to be_nil
    end

    it 'offers the reset to the BARE route once something narrows the list' do
      get_list(search: 'pselector')

      reset = doc.at_css('#billing_filter_reset a[data-filter-reset]')
      expect(reset).to be_present
      expect(reset['href']).to eq(organisation_time_session_groups_path(organisation))
    end

    it 'carries pill-set filters as hidden fields so a search submit keeps them' do
      get_list(billing_states: ['billed'], project_id: project_a.id, date_range: 'year')

      form = doc.at_css("form[action=\"#{organisation_time_session_groups_path(organisation)}\"]")
      expect(form.css('input[name="billing_states[]"]').map { |i| i['value'] }).to eq(['billed'])
      expect(form.at_css("input[name=\"project_id\"][value=\"#{project_a.id}\"]")).to be_present
      expect(form.at_css('input[name="date_range"][value="year"]')).to be_present
    end
  end

  describe 'the result summary' do
    it 'states the filtered count and the policy-scoped duration' do
      create_group(project: project_a, sessions: 2, minutes: 90)

      get_list

      summary = doc.at_css('#billing_result_summary')
      expect(summary.text).to include('1 Abrechnung')
      expect(summary.text).to include('03:00')
    end
  end

  describe 'the frame answer' do
    let!(:group) { create_group(project: project_a) }

    # The regions sit OUTSIDE time_session_groups_list_frame while the search
    # targets it. The streams have to travel INSIDE the frame element: after
    # </turbo-frame> Turbo discards them - present in the body, green in a spec
    # that only greps the body, and never applied. So the POSITION is the
    # assertion, not the presence.
    it 'streams the result summary and the reset INSIDE the frame' do
      get organisation_time_session_groups_path(organisation, search: 'x'),
          headers: { 'Turbo-Frame' => 'time_session_groups_list_frame' }
      expect(response).to have_http_status(:ok)

      frame = doc.at_css('turbo-frame#time_session_groups_list_frame')
      targets = frame.css('turbo-stream').map { |s| s['target'] }
      expect(targets).to include('billing_result_summary', 'billing_filter_reset')
    end

    it 'does not stream the regions on a full page load' do
      get_list

      expect(doc.css('turbo-stream')).to be_empty
    end
  end
end
