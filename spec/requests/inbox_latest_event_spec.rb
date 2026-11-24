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

  # A row the fanout creates late (an outbox event retried after a failure) starts at
  # the time of its activity, not of its delivery (GroupKeyBuilder#create_new_group).
  # It stands where the token inbox has always put it: the web inbox has no second
  # order of its own (one that put a late row on top by its created_at would split
  # the two).
  describe 'a row the fanout creates late' do
    let!(:late) do
      ticket = ticket_titled('Spät verteilt')
      activity = ActsAsTenant.with_tenant(organisation) do
        create(:activity, actor: create(:user), organisation: organisation, trackable: ticket,
                          action: 'ticket_commented', key: 'ticket.ticket_commented', created_at: 2.days.ago)
      end
      ActsAsTenant.with_tenant(organisation) do
        Notifications::GroupKeyBuilder.new(activity, user).find_or_create_group(
          recipient_id: user.id, actor_id: activity.actor_id, notifiable_type: 'Ticket', notifiable_id: ticket.id,
          event_type: 'ticket_commented', channel: 'in_app', payload: { 'action' => 'commented' },
          organisation_id: organisation.id
        )
      end
    end
    # Written after the late row: without an order the table would hand them back as written.
    let!(:yesterday) { row_about(ticket_titled('Gestern'), created_at: 1.day.ago) }
    let(:token) do
      pat = build(:personal_access_token, user: user, organisations: [organisation], read_only: true)
      pat.token_hash = nil
      pat.token_prefix = nil
      pat.generate_token!
      pat
    end

    before { make_token_owner_a_member(user, organisation, projects: [project]) }

    it 'stands where the token inbox puts it, at the time of its activity' do
      expect(late.created_at).to be > yesterday.created_at
      expect(late.last_event_at).to be < yesterday.last_event_at

      get '/api/v1/notifications', params: { status: 'all' }, headers: { 'Authorization' => "Bearer #{token.token}" }
      expect(response).to have_http_status(:ok)
      token_order = JSON.parse(response.body)['data'].pluck('id')

      get organisation_notifications_path(organisation, view_mode: 'chronological')
      expect(response).to have_http_status(:ok)
      web = Nokogiri::HTML(response.body)
      expect(row_ids(web)).to eq([yesterday.id, late.id])
      expect(row_ids(web)).to eq(token_order)
    end
  end
end
