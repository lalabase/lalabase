# frozen_string_literal: true

require 'rails_helper'

# What: the inbox of one organisation reads a row by its latest event
#       (last_event_at), the order of the token inbox. A row created days ago
#       that got an event a moment ago (GroupKeyBuilder folds it in, its
#       created_at stays) is the most recent row: first in the bundled and in
#       the chronological list, first in the lane's "what was new" block with
#       the time of that event, and first in the list the two bulk answers redraw.
#       Real time throughout: the pages render avatars.
RSpec.describe 'Inbox by the latest event of a row', type: :request do
  before { Prosopite.pause } # pre-existing N+1 in the render path
  after  { Prosopite.resume }

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  def ticket_titled(title)
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, title: title) }
  end

  # last_event_at: the row's latest event, which moves when a later event folds into
  # the row; created_at does not. The factory lets both follow created_at.
  def row_about(ticket, created_at:, last_event_at: created_at, **attributes)
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation, project: project, notifiable: ticket,
             event_type: 'ticket_commented', channel: 'in_app', state: :delivered,
             created_at: created_at, first_event_at: created_at, last_event_at: last_event_at, **attributes)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  after { ActsAsTenant.current_tenant = nil }

  let(:list_address) { organisation_notifications_path(organisation, state_filters: %w[read unread]) }

  # The ids of the rows of a list, in the order the page draws them.
  def row_ids(node)
    node.css('#inbox_master_list [data-notification-item]').pluck('data-notification-item')
  end

  describe 'the list' do
    # The row with the latest event is written last: without an order the table hands
    # rows back as written, so it must not come first by accident.
    let!(:new_but_quiet) { row_about(ticket_titled('Gerade neu'), created_at: 1.hour.ago) }
    let!(:old_but_active) { row_about(ticket_titled('Lange offen'), created_at: 3.days.ago, last_event_at: 5.minutes.ago) }

    def list_page(**params)
      get organisation_notifications_path(organisation, state_filters: %w[read unread], **params)
      expect(response).to have_http_status(:ok)
      Nokogiri::HTML(response.body)
    end

    it 'shows the row with the latest event first in the bundled view' do
      expect(row_ids(list_page)).to eq([old_but_active.id, new_but_quiet.id])
    end

    it 'shows the row with the latest event first in the chronological view' do
      expect(row_ids(list_page(view_mode: 'chronological'))).to eq([old_but_active.id, new_but_quiet.id])
    end

    describe 'the two bulk answers' do
      # A third row, the only one the bulk bar acts on: the other two stay in the list.
      let!(:selected) { row_about(ticket_titled('Ausgewaehlt'), created_at: 2.hours.ago) }

      def bulk(path)
        patch path, params: { selection: '1', ids: [selected.id] },
                    headers: { 'Accept' => 'text/vnd.turbo-stream.html',
                               'Referer' => "http://www.example.com#{list_address}" }
        expect(response).to have_http_status(:ok)
        Nokogiri::HTML(response.body).at_css('turbo-stream[target="inbox_master_list"]')
      end

      it 'redraws the list of mark_all_read with the row with the latest event first' do
        list = bulk(mark_all_read_organisation_notifications_path(organisation))

        expect(selected.reload.state).to eq('read')
        expect(row_ids(list)).to eq([old_but_active.id, new_but_quiet.id, selected.id])
      end

      it 'redraws the list of archive_all with the row with the latest event first' do
        list = bulk(archive_all_organisation_notifications_path(organisation))

        expect(selected.reload.state).to eq('archived')
        expect(row_ids(list)).to eq([old_but_active.id, new_but_quiet.id])
      end
    end
  end

  describe 'the lane' do
    let(:ticket) { ticket_titled('Lange offen') }
    let(:active_actor) { create(:user, first_name: 'Ada', last_name: 'Aktiv') }
    let(:quiet_actor) { create(:user, first_name: 'Nils', last_name: 'Neu') }
    let!(:new_but_quiet) { row_about(ticket, created_at: 1.hour.ago, actor: quiet_actor) }
    # Written last, see the list above.
    let!(:old_but_active) do
      row_about(ticket, created_at: 3.days.ago, last_event_at: 5.minutes.ago, actor: active_actor)
    end

    it 'lists the row with the latest event first in "what was new", with the time of that event' do
      get organisation_notifications_path(organisation, state_filters: %w[read unread], notification: new_but_quiet.id)
      expect(response).to have_http_status(:ok)

      lines = Nokogiri::HTML(response.body).css('.inbox-new-activity__item')
      expect(lines.map { |line| line.at_css('.inbox-new-activity__who').text.strip }).to eq(['Ada Aktiv', 'Nils Neu'])
      minutes = I18n.with_locale(:de) do
        I18n.t('views.common.relative_time_ago', time: I18n.t('datetime.distance_in_words.x_minutes', count: 5))
      end
      expect(lines.first.at_css('.inbox-new-activity__time').text.strip).to eq(minutes)
    end
  end

  # A row the fanout writes late (an outbox event delayed, or retried after a failure)
  # stands at the moment its event reached it, the time of the write, not at the time
  # of its activity (Notifications::RowEvents.arrival, asked by GroupKeyBuilder). So it
  # is new and on top: first in the web inbox and in the token inbox by arrival
  # (arrived_since), which share the one order; under the heading and inside the
  # period of the day it arrived; and a client that polls the token inbox with
  # arrived_since gets it. The token inbox without arrived_since keeps what API 1.15
  # said: last_event_at, `since` and the order are the time of the activity. A fold
  # is a write as well: an earlier event that reaches a row late moves the row up.
  describe 'a row the fanout creates late' do
    # The row the builder writes now for an activity that happened at another time.
    def written_now_for(ticket, activity_at:)
      activity = ActsAsTenant.with_tenant(organisation) do
        create(:activity, actor: create(:user), organisation: organisation, trackable: ticket,
                          action: 'ticket_commented', key: 'ticket.ticket_commented', created_at: activity_at)
      end
      ActsAsTenant.with_tenant(organisation) do
        Notifications::GroupKeyBuilder.new(activity, user).find_or_create_group(
          recipient_id: user.id, actor_id: activity.actor_id, notifiable_type: 'Ticket', notifiable_id: ticket.id,
          event_type: 'ticket_commented', channel: 'in_app', payload: { 'action' => 'commented' },
          organisation_id: organisation.id
        )
      end
    end

    # Written before the late row and expected below it: without an order the table
    # hands rows back as written, so the late row must not come first by accident.
    let!(:day_before) { row_about(ticket_titled('Vorgestern'), created_at: 36.hours.ago) }
    let!(:late) { written_now_for(ticket_titled('Spät verteilt'), activity_at: 2.days.ago) }
    # Written after the late row, with a latest event between its activity and its write.
    let!(:yesterday) { row_about(ticket_titled('Gestern'), created_at: 1.day.ago) }
    let(:token) do
      pat = build(:personal_access_token, user: user, organisations: [organisation], read_only: true)
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
      pat
    end

    before { make_token_owner_a_member(user, organisation, projects: [project]) }

    def token_rows(**params)
      get '/api/v1/notifications', params: { status: 'all', **params },
                                   headers: { 'Authorization' => "Bearer #{token.token}" }
      expect(response).to have_http_status(:ok)
      JSON.parse(response.body)['data']
    end

    def token_inbox(**params)
      token_rows(**params).pluck('id')
    end

    # The token inbox by arrival, every row of these examples: they all reached
    # the inbox within the last three days.
    def token_inbox_by_arrival
      token_inbox(arrived_since: 3.days.ago.iso8601)
    end

    def web_inbox(view_mode: 'chronological', **params)
      get organisation_notifications_path(organisation, view_mode: view_mode, **params)
      expect(response).to have_http_status(:ok)
      Nokogiri::HTML(response.body)
    end

    it 'stands on top, in the web inbox as in the token inbox by arrival' do
      expect(late.created_at).to be > yesterday.created_at
      expect(late.first_event_at).to be < day_before.last_event_at
      expect(late.last_event_at).to be > yesterday.last_event_at

      token_order = token_inbox_by_arrival

      web = web_inbox
      expect(row_ids(web)).to eq([late.id, yesterday.id, day_before.id])
      expect(row_ids(web)).to eq(token_order)
    end

    it 'reaches a client that polls the token inbox with arrived_since set between its activity and its write' do
      since = 1.hour.ago
      expect(late.first_event_at).to be < since
      expect(late.created_at).to be > since
      expect(token_inbox_by_arrival).to eq([late.id, yesterday.id, day_before.id])

      expect(token_inbox(arrived_since: since.iso8601)).to eq([late.id])
    end

    # A client of API 1.15 reads the same fields, cursor and order as before: the
    # late row stands at the time of its activity and below a cursor set after it.
    it 'keeps the time of its activity in the token inbox without arrived_since' do
      expect(token_inbox).to eq([yesterday.id, day_before.id, late.id])
      expect(token_inbox(since: 1.hour.ago.iso8601)).to be_empty

      fields = token_rows.find { |row| row['id'] == late.id }

      expect(Time.zone.parse(fields['last_event_at'])).to be_within(1.second).of(late.happened_at)
      expect(Time.zone.parse(fields['arrived_at'])).to be_within(1.second).of(late.last_event_at)
      expect(late.last_event_at - late.happened_at).to be > 2.days - 1.minute
    end

    # { notification id => the period heading it stands under }, in the order of the
    # list. Only the bundled view draws the headings.
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

    it 'counts on the day it arrived: inside the last 90 days and under today, for an activity before them' do
      long_late = written_now_for(ticket_titled('Sehr spät verteilt'), activity_at: 100.days.ago)
      stale = row_about(ticket_titled('Lange still'), created_at: 100.days.ago)
      expect(long_late.first_event_at).to be < 90.days.ago
      expect(headings_by_row(web_inbox(view_mode: 'grouped'))).to include(long_late.id => 'today', stale.id => 'older')

      narrowed = headings_by_row(web_inbox(view_mode: 'grouped', period: '90_days'))

      expect(narrowed).to include(long_late.id => 'today', late.id => 'today')
      expect(narrowed.keys).to contain_exactly(long_late.id, late.id, yesterday.id, day_before.id)
    end

    # The time a row prints is when its event happened (happened_at), not when it
    # reached the row: on top, and two days ago.
    it 'names the time of its activity, not the time of its write' do
      expect(late.happened_at).to be_within(1.second).of(2.days.ago)
      expect(late.last_event_at).to be > 1.minute.ago

      time = web_inbox.at_css("[data-notification-item='#{late.id}'] .inbox-row__time").text.strip

      expect(time).to eq(I18n.with_locale(:de) do
        I18n.t('views.common.relative_time_ago', time: I18n.t('datetime.distance_in_words.x_days', count: 2))
      end)
    end

    # The bundled view draws one line per ticket: the row whose latest event
    # happened last (happened_at) speaks for it, here the row written in time, so
    # the line says what the ticket's newest event was. The bundle stands where
    # its newest arrival stands: on top, with the late row it does not show.
    # (Both rules without the fanout: master_list_presenter_spec.rb.)
    it 'puts its ticket on top in the bundled view, under the line of the row with the later event' do
      ticket = ticket_titled('Zwei Zeilen')
      written_in_time = row_about(ticket, created_at: 1.hour.ago)
      late_comment = written_now_for(ticket, activity_at: 3.hours.ago)
      expect(late_comment.id).not_to eq(written_in_time.id)
      expect(late_comment.happened_at).to be < written_in_time.happened_at
      expect(late_comment.last_event_at).to be > late.last_event_at
      expect(row_ids(web_inbox)).to include(late_comment.id, written_in_time.id)

      page = web_inbox(view_mode: 'grouped')
      bundled = row_ids(page)

      expect(bundled).to eq([written_in_time.id, late.id, yesterday.id, day_before.id])
      expect(headings_by_row(page)).to include(written_in_time.id => 'today')
      expect(page.at_css("[data-notification-item='#{written_in_time.id}'] .inbox-row__time").text.strip)
        .to eq(I18n.with_locale(:de) do
          I18n.t('views.common.relative_time_ago', time: I18n.t('datetime.distance_in_words.about_x_hours', count: 1))
        end)
    end

    # Both activities lie in one five-minute bucket that is over, so they share a row.
    # The clock is moved for the two writes only; the lists are drawn in real time.
    context 'when an earlier event folds into the row late' do
      include ActiveSupport::Testing::TimeHelpers

      let(:bucket_start) { Time.zone.at((10.minutes.ago.to_i / 300) * 300) }
      let(:ticket) { ticket_titled('Zwei Ereignisse') }

      it 'moves the row above a row whose latest event lies between the two writes' do
        row = travel_to(bucket_start + 190.seconds) { written_now_for(ticket, activity_at: bucket_start + 3.minutes) }
        between = row_about(ticket_titled('Dazwischen'), created_at: bucket_start + 220.seconds)
        expect(row.reload).to have_attributes(group_count: 1, last_event_at: bucket_start + 190.seconds)
        expect(row.last_event_at).to be < between.last_event_at

        folded = travel_to(bucket_start + 260.seconds) { written_now_for(ticket, activity_at: bucket_start + 30.seconds) }

        expect(folded.id).to eq(row.id)
        expect(row.reload).to have_attributes(group_count: 2, first_event_at: bucket_start + 30.seconds,
                                              last_event_at: bucket_start + 260.seconds)
        token_order = token_inbox_by_arrival
        web = row_ids(web_inbox)
        expect(web).to eq(token_order)
        expect(web.first(3)).to eq([late.id, row.id, between.id])
      end
    end
  end
end
