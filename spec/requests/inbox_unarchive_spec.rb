# frozen_string_literal: true

require 'rails_helper'

# PATCH /inbox/:id/unarchive — brings an archived notification back
# into the :read state, sets archived_at: nil. Symmetric to archive,
# uses the archive? policy (whoever may archive may also unarchive).
RSpec.describe 'Inbox unarchive action', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership,
             user: user, organisation: organisation, role: role, active: true)
    end
  end

  let!(:archived_notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification,
             recipient: user, organisation: organisation,
             channel: 'in_app', state: :archived,
             archived_at: 1.day.ago, read_at: 2.days.ago)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause
  end
  after { Prosopite.resume }

  describe 'PATCH /inbox/:id/unarchive' do
    it 'setzt State von archived auf read' do
      expect do
        patch unarchive_organisation_notification_path(organisation, archived_notification)
      end.to change { archived_notification.reload.state }.from('archived').to('read')
    end

    it 'setzt archived_at auf nil zurück' do
      patch unarchive_organisation_notification_path(organisation, archived_notification)
      expect(archived_notification.reload.archived_at).to be_nil
    end

    it 'behält das ursprüngliche read_at (kein Neu-Setzen wenn schon vorhanden)' do
      original_read_at = archived_notification.read_at
      patch unarchive_organisation_notification_path(organisation, archived_notification)
      expect(archived_notification.reload.read_at.to_i).to eq(original_read_at.to_i)
    end

    it 'is no-op bei bereits ungelesen/gelesen Notifications' do
      read_n = ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation,
                              channel: 'in_app', state: :read, read_at: 1.hour.ago)
      end
      expect do
        patch unarchive_organisation_notification_path(organisation, read_n)
      end.not_to(change { read_n.reload.state })
    end

    it 'verweigert Zugriff auf fremde Notifications' do
      other_user = create(:user)
      other_membership = nil
      foreign_n = ActsAsTenant.with_tenant(organisation) do
        other_membership = create(:membership, user: other_user, organisation: organisation,
                                               role: role, active: true)
        create(:notification, recipient: other_user, organisation: organisation,
                              channel: 'in_app', state: :archived,
                              archived_at: 1.day.ago)
      end
      patch unarchive_organisation_notification_path(organisation, foreign_n)
      expect(foreign_n.reload.state).to eq('archived')
    end
  end
end
