# frozen_string_literal: true

require 'rails_helper'

# Supplementary QA-matrix cases (round 2, extended):
# - H2: state-change when item still matches the filter → stays visible
# - H5: completely empty inbox → up_to_date text instead of try_different_filters
# - H6: banner visibility across filters (bug #8 regression guard)
RSpec.describe 'Inbox banner + state-change matrix', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end
  let!(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end
  let!(:ticket) do
    ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause
  end
  after { Prosopite.resume }

  def presenter
    controller.instance_variable_get(:@presenter)
  end

  describe 'H6: show_unread_banner? je nach Filter' do
    it 'zeigt Banner bei leerem Filter (Default-View)' do
      get organisation_notifications_path(organisation), params: { state_filters: [''] }
      expect(presenter.show_unread_banner?).to be true
    end

    it 'zeigt Banner wenn unread aktiv' do
      get organisation_notifications_path(organisation), params: { state_filters: ['unread'] }
      expect(presenter.show_unread_banner?).to be true
    end

    it 'versteckt Banner wenn NUR read aktiv' do
      get organisation_notifications_path(organisation), params: { state_filters: ['read'] }
      expect(presenter.show_unread_banner?).to be false
    end

    it 'versteckt Banner wenn NUR archived aktiv' do
      get organisation_notifications_path(organisation), params: { state_filters: ['archived'] }
      expect(presenter.show_unread_banner?).to be false
    end

    it 'zeigt Banner wenn read+unread aktiv' do
      get organisation_notifications_path(organisation), params: { state_filters: %w[read unread] }
      expect(presenter.show_unread_banner?).to be true
    end
  end

  describe 'H5: Empty-State-Texte' do
    it 'has_active_filters? true wenn nur read gefiltert und keine read da' do
      # Only 1 unread notification exists → read filter is empty
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation,
                              channel: 'in_app', state: :delivered, notifiable: ticket, project: project)
      end
      get organisation_notifications_path(organisation), params: { state_filters: ['read'] }
      expect(presenter.empty?).to be true
      expect(presenter.has_active_filters?).to be true # → "try_different_filters"
    end

    it 'has_active_filters? false bei Default-View ohne irgendwelche Notifications' do
      # No notifications at all → default view (empty filter) is empty
      get organisation_notifications_path(organisation), params: { state_filters: [''] }
      expect(presenter.empty?).to be true
      expect(presenter.has_active_filters?).to be false # → "up_to_date"
    end
  end

  describe 'H2: State-Change wenn Item weiter zum Filter passt' do
    let!(:notification) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation,
                              notifiable: ticket, project: project,
                              channel: 'in_app', state: :delivered)
      end
    end

    it 'unread→read bleibt in der Liste wenn Filter unread+read umfasst' do
      # mark_read from the pane, referrer has unread+read filter
      patch mark_read_organisation_notification_path(organisation, notification),
            headers: { 'Referer' => organisation_notifications_path(organisation, state_filters: %w[unread read]) }
      # Notification is now read, but read is in the filter → stays visible.
      # We check the filter-match logic in the controller.
      still_in = controller.send(:notification_matches_state_filters?,
                                 notification.reload, %w[unread read])
      expect(still_in).to be true
    end

    it 'unread→read verschwindet wenn Filter NUR unread umfasst' do
      patch mark_read_organisation_notification_path(organisation, notification),
            headers: { 'Referer' => organisation_notifications_path(organisation, state_filters: %w[unread]) }
      still_in = controller.send(:notification_matches_state_filters?,
                                 notification.reload, %w[unread])
      expect(still_in).to be false
    end
  end
end
