# frozen_string_literal: true

require 'rails_helper'

# What: a period filter in the inbox, like the time list's (user, 2026-11-10),
#       "gesamter Zeitraum" chosen by default. The periods are the time
#       area's (TimeSessions::ListPeriod: the eight presets, their order,
#       labels and bounds), not a second list; a notification counts by the
#       day its latest event reached it (last_event_at) in the reader's time
#       zone: a row created long ago that got an event today is a row of today.
#       The period narrows like search and project: it travels with every
#       link of the list, survives the streams of a row action, and the empty
#       list's reset drops it.
RSpec.describe 'Inbox period filter', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { Prosopite.pause } # pre-existing N+1 in the render path
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, timezone: 'Berlin') }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  # last_event_at: the row's latest event, which moves when a later event folds into
  # the row; created_at does not. The factory lets both follow created_at.
  def notification_for(title, created_at:, last_event_at: created_at)
    ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: title) }
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation, project: project, notifiable: ticket,
             event_type: 'ticket_commented', channel: 'in_app', state: :delivered,
             created_at: created_at, first_event_at: created_at, last_event_at: last_event_at)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  after { ActsAsTenant.current_tenant = nil }

  def shown_ids
    controller.instance_variable_get(:@notifications).map(&:id)
  end

  def list_page(**params)
    get organisation_notifications_path(organisation, state_filters: %w[read unread], **params)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  describe 'the select' do
    it 'offers the eight periods of the time area, "Gesamter Zeitraum" chosen' do
      select = list_page.at_css('select[name="period"]')

      expect(select).to be_present
      expect(select.css('option').map { |option| option['value'] }).to eq(TimeSessions::ListPeriod::KEYS)
      expect(select.css('option').map(&:text)).to eq(TimeSessions::ListPeriod::KEYS.map { |key|
        TimeSessions::ListPeriod.label(key).upcase_first
      })
      expect(select.at_css('option[selected]')['value']).to eq('all')
    end

    it 'marks the chosen period, and the search form carries it' do
      doc = list_page(period: 'this_month')

      expect(doc.at_css('select[name="period"] option[selected]')['value']).to eq('this_month')
      expect(doc.at_css('form.inbox-search input[type="hidden"][name="period"]')['value']).to eq('this_month')
    end
  end

  describe 'the rows' do
    # Monday 2026-11-09, 00:30 in Berlin = Sunday 23:30 UTC.
    around { |example| travel_to(Time.utc(2026, 11, 8, 23, 30)) { example.run } }

    # Created long ago; its latest event came this week.
    let!(:this_week) do
      notification_for('Diese Woche', created_at: Time.utc(2025, 6, 2, 12), last_event_at: Time.utc(2026, 11, 8, 23, 10))
    end
    let!(:last_month) { notification_for('Letzter Monat', created_at: Time.utc(2026, 10, 2, 12)) }
    let!(:years_ago) { notification_for('Vor Jahren', created_at: Time.utc(2024, 3, 1, 12)) }

    it 'shows every notification by default' do
      list_page

      expect(shown_ids).to contain_exactly(this_week.id, last_month.id, years_ago.id)
    end

    it "counts a notification by the day of its latest event in the reader's time zone" do
      # Both created long ago. 23:10 UTC on Sunday is 00:10 on Monday in Berlin: this
      # week there. 22:50 UTC is 23:50 on Sunday in Berlin: last week there, though
      # this week in UTC.
      notification_for('Sonntag', created_at: Time.utc(2025, 6, 2, 12), last_event_at: Time.utc(2026, 11, 8, 22, 50))
      list_page(period: 'this_week')

      expect(shown_ids).to eq([this_week.id])
    end

    it 'narrows to the last 90 days' do
      list_page(period: '90_days')

      expect(shown_ids).to contain_exactly(this_week.id, last_month.id)
    end

    it 'takes an unknown period for the whole time' do
      list_page(period: 'gestern')

      expect(shown_ids).to contain_exactly(this_week.id, last_month.id, years_ago.id)
    end

    it 'keeps the period when a row action redraws the list' do
      patch mark_read_organisation_notification_path(organisation, last_month),
            headers: { 'Accept' => 'text/vnd.turbo-stream.html',
                       'Referer' => "http://www.example.com#{organisation_notifications_path(organisation, state_filters: %w[read unread], period: 'this_week')}" }

      list = Nokogiri::HTML(response.body.scan(%r{<template>(.*?)</template>}m).flatten.join)
      titles = list.css('.inbox-row__title').map { |title| title.text.strip }
      expect(titles).to eq(['Diese Woche'])
    end

    it 'counts as narrowing: a list empty by the period alone offers to drop it' do
      this_week.destroy!
      doc = list_page(period: 'this_week')

      expect(controller.instance_variable_get(:@presenter).empty_reason).to eq(:no_match)
      reset = doc.at_css('.inbox-empty a')['href']
      expect(reset).not_to include('period')
      expect(reset).not_to include('search')
    end
  end

  # A row created 100 days ago that got an event a moment ago, and one whose latest
  # event is 100 days old. Real time: the list renders avatars.
  describe 'a row by its latest event' do
    let!(:revived) { notification_for('Wieder aktiv', created_at: 100.days.ago, last_event_at: Time.current) }
    let!(:stale) { notification_for('Lange still', created_at: 100.days.ago) }

    # { notification id => the period heading it stands under }, in the order of the list.
    def headings_by_row(doc)
      heading = nil
      doc.css('#inbox_master_list .inbox-period, #inbox_master_list [data-notification-item]').each_with_object({}) do |node, rows|
        if node.matches?('.inbox-period')
          heading = node['data-date-header']
        else
          rows[node['data-notification-item']] = heading
        end
      end
    end

    it 'keeps the row with an event today inside the last 90 days, under today, and leaves out the other' do
      doc = list_page(period: '90_days')

      expect(shown_ids).to eq([revived.id])
      expect(headings_by_row(doc)).to eq(revived.id => 'today')
      expect(doc.at_css('#inbox_master_list .inbox-period').text.strip)
        .to eq(I18n.t('views.organisations.notifications.periods.today'))
    end

    it 'reads "all" and an unknown key as no window: both rows, each under the day of its latest event' do
      [{ period: 'all' }, { period: 'gestern' }].each do |params|
        doc = list_page(**params)

        expect(headings_by_row(doc)).to eq(revived.id => 'today', stale.id => 'older')
      end
    end

    it 'redraws the list of a bulk action with the rows the period shows' do
      patch mark_all_read_organisation_notifications_path(organisation),
            params: { selection: '1', ids: [revived.id] },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html',
                       'Referer' => "http://www.example.com#{organisation_notifications_path(organisation, state_filters: %w[read unread], period: '90_days')}" }

      expect(response).to have_http_status(:ok)
      expect(revived.reload.state).to eq('read')
      expect(stale.reload.state).to eq('delivered')
      list = Nokogiri::HTML(response.body).at_css('turbo-stream[target="inbox_master_list"]')
      expect(headings_by_row(list)).to eq(revived.id => 'today')
    end
  end
end
