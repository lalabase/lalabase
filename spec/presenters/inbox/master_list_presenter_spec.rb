# frozen_string_literal: true

require 'rails_helper'

# Minimal Pagy host: the presenter calls pagy_helper.send(:pagy, ...).
class FakePagyHelper
  include Pagy::Backend

  def initialize(params = {})
    @params = params
  end

  attr_reader :params
end

RSpec.describe Inbox::MasterListPresenter do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket_a) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }
  let(:ticket_b) { ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) } }

  let(:scope) { Notification.where(recipient: user, channel: 'in_app') }

  def notif(ticket, created_at:, state: 'queued')
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation, project: project,
             notifiable: ticket, channel: 'in_app', state: state,
             created_at: created_at, read_at: state == 'read' ? created_at : nil)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }

  def build(params = {})
    described_class.new(
      pagy_helper: FakePagyHelper.new,
      scope: scope,
      params: { view_mode: 'grouped' }.merge(params)
    )
  end

  describe 'Bündelung im grouped-View' do
    it 'fasst mehrere Notifications eines Tickets zu EINER Zeile zusammen' do
      notif(ticket_a, created_at: 3.hours.ago)
      notif(ticket_a, created_at: 2.hours.ago)
      newest_a = notif(ticket_a, created_at: 1.hour.ago)
      notif(ticket_b, created_at: 90.minutes.ago)

      presenter = build

      # 2 tickets → 2 rows (not 4 notifications)
      expect(presenter.notifications.size).to eq(2)
      # The representative of ticket A is the NEWEST notification
      rep_a = presenter.notifications.find { |n| n.notifiable_id == ticket_a.id }
      expect(rep_a.id).to eq(newest_a.id)
    end

    it 'liefert group_total = Gesamtzahl der Notifications des Tickets' do
      notif(ticket_a, created_at: 3.hours.ago)
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_a, created_at: 1.hour.ago)

      presenter = build
      rep_a = presenter.notifications.first
      expect(presenter.group_total(rep_a)).to eq(3)
    end

    it 'liefert group_unread = Anzahl ungelesener des Tickets' do
      notif(ticket_a, created_at: 3.hours.ago, state: 'read')
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_a, created_at: 1.hour.ago)

      presenter = build
      rep_a = presenter.notifications.first
      expect(presenter.group_unread(rep_a)).to eq(2)
    end

    it 'zeigt ein tagesübergreifend aktives Ticket nur EINMAL, unter dem neuesten Tag' do
      notif(ticket_a, created_at: 2.days.ago)
      newest = notif(ticket_a, created_at: 1.hour.ago)

      presenter = build

      expect(presenter.notifications.size).to eq(1)
      dates = presenter.grouped_notifications.keys
      expect(dates).to eq([newest.created_at.to_date])
    end
  end

  describe 'chronologischer View (kein Bündeln)' do
    it 'rendert jede Notification einzeln' do
      notif(ticket_a, created_at: 2.hours.ago)
      notif(ticket_a, created_at: 1.hour.ago)

      presenter = build(view_mode: 'chronological')
      expect(presenter.notifications.size).to eq(2)
    end
  end
end
