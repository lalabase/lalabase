# frozen_string_literal: true

require 'rails_helper'

# What: the activities popover of a notification (GET .../inbox/:id/activities)
#       dates its lines from when the row's latest event happened (happened_at),
#       never from when that event reached the row (last_event_at). A grouped
#       row keeps no time per actor, so the lines are estimated back from the
#       latest event, never before the earliest one (first_event_at), the
#       actor of the latest event first: RowEvents.fold! keeps actor_ids oldest
#       first, the leading actor last. A single row shows the time of its event,
#       not of its write (created_at).
# Why: since a row stands at the moment its event reached it
#       (Notifications::RowEvents.arrival), a retried fanout would have dated
#       every actor by its delay, up to the 72 hours of the outbox's retries.
#       Until 2026-11-26 the action called time_ago_in_words on the controller,
#       which has no such method, and answered every request with its 500.
RSpec.describe 'Notification group activities', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }
  let(:now) { Time.zone.local(2026, 11, 24, 15, 0, 0) }
  let(:first_actor) { create(:user, first_name: 'Ada', last_name: 'Erste') }
  let(:second_actor) { create(:user, first_name: 'Ben', last_name: 'Zweite') }

  # The row of a group whose earliest event happened at 09:00 and whose latest one
  # (14:00) reached it now, a retried fanout of an hour. Ada commented first, Ben
  # last: actor_ids as a fold writes them, the leading actor last.
  def row(**attributes)
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation, project: project, notifiable: ticket,
             event_type: 'ticket_commented', channel: 'in_app', state: :delivered, actor: second_actor,
             payload: { 'action' => 'commented', 'actor_ids' => [first_actor.id, second_actor.id] },
             created_at: now - 6.hours, first_event_at: now - 6.hours, happened_at: now - 1.hour,
             last_event_at: now, **attributes)
    end
  end

  before do
    travel_to(now)
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
    travel_back
  end

  # [actor name, the time of its line] per line, in the order of the popover.
  def lines(notification)
    get activities_organisation_notification_path(organisation, notification)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body).css('.activity-item').map do |item|
      [item.at_css('strong').text.strip, item.at_css('.activity-time').text.strip]
    end
  end

  def ago(key, count)
    I18n.with_locale(:de) { I18n.t("datetime.distance_in_words.#{key}", count: count) }
  end

  it 'dates the lines of a group back from when its latest event happened, not from its arrival' do
    group = row(group_count: 2)

    expect(lines(group)).to eq([['Ben Zweite', ago(:about_x_hours, 1)], ['Ada Erste', ago(:about_x_hours, 1)]])
  end

  # Six actors, 30 seconds apart from the latest event (one minute ago) back: the
  # sixth would stand 3.5 minutes ago, before the earliest event two minutes ago.
  # Person5 commented last and leads, Person0 commented first.
  it 'dates no line of a group before its earliest event, the latest actor first' do
    actors = Array.new(6) { |index| create(:user, first_name: "Person#{index}", last_name: 'Beispiel') }
    group = row(group_count: 6, actor: actors.last, first_event_at: now - 2.minutes, happened_at: now - 1.minute,
                payload: { 'action' => 'commented', 'actor_ids' => actors.map(&:id) })

    shown = lines(group)

    expect(shown.first).to eq(['Person5 Beispiel', ago(:x_minutes, 1)])
    expect(shown.last).to eq(['Person0 Beispiel', ago(:x_minutes, 2)])
    expect(shown.map(&:last)).not_to include(ago(:x_minutes, 3), ago(:x_minutes, 4))
  end

  it 'dates a single row by the time of its event, not by its write' do
    single = row(group_count: 1, created_at: now, first_event_at: now - 2.days, happened_at: now - 2.days,
                 payload: { 'action' => 'commented' })

    expect(lines(single).map(&:last)).to eq([ago(:x_days, 2)])
  end
end
