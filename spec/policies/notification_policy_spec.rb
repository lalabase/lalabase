# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NotificationPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:recipient) { create(:user) }
  let(:other_user) { create(:user) }

  let(:notification) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, recipient: recipient, organisation: organisation)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # --- index? ---
  describe '#index?' do
    it 'erlaubt jedem eingeloggten User den Zugriff' do
      expect(described_class.new(recipient, notification).index?).to be true
      expect(described_class.new(other_user, notification).index?).to be true
    end
  end

  # --- Shared behaviour for owner+tenant gated actions ---
  shared_examples 'owner and tenant gated action' do |method|
    context 'als Empfänger in derselben Organisation' do
      it 'erlaubt den Zugriff' do
        expect(described_class.new(recipient, notification).public_send(method)).to be true
      end
    end

    context 'als anderer User in derselben Organisation' do
      it 'verweigert den Zugriff' do
        expect(described_class.new(other_user, notification).public_send(method)).to be false
      end
    end

    context 'als Empfänger in einer anderen Organisation' do
      it 'verweigert den Zugriff' do
        ActsAsTenant.current_tenant = other_organisation
        expect(described_class.new(recipient, notification).public_send(method)).to be false
      end
    end

    context 'als anderer User in einer anderen Organisation' do
      it 'verweigert den Zugriff' do
        ActsAsTenant.current_tenant = other_organisation
        expect(described_class.new(other_user, notification).public_send(method)).to be false
      end
    end
  end

  describe '#show?' do
    it_behaves_like 'owner and tenant gated action', :show?
  end

  describe '#update?' do
    it_behaves_like 'owner and tenant gated action', :update?
  end

  describe '#destroy?' do
    it_behaves_like 'owner and tenant gated action', :destroy?
  end

  describe '#mark_read?' do
    it_behaves_like 'owner and tenant gated action', :mark_read?
  end

  describe '#mark_unread?' do
    it_behaves_like 'owner and tenant gated action', :mark_unread?
  end

  describe '#archive?' do
    it_behaves_like 'owner and tenant gated action', :archive?
  end

  describe '#mark_group_read?' do
    it_behaves_like 'owner and tenant gated action', :mark_group_read?
  end

  describe '#activities?' do
    it_behaves_like 'owner and tenant gated action', :activities?
  end

  describe '#open?' do
    it 'delegiert an show?' do
      policy = described_class.new(recipient, notification)
      expect(policy.open?).to eq(policy.show?)
    end

    it 'verweigert den Zugriff für fremde User' do
      policy = described_class.new(other_user, notification)
      expect(policy.open?).to be false
    end
  end

  # --- ApplicationPolicy guard ---
  describe 'ApplicationPolicy Guard' do
    it 'wirft Pundit::NotAuthorizedError ohne User' do
      expect { described_class.new(nil, notification) }
        .to raise_error(Pundit::NotAuthorizedError, 'must be logged in')
    end
  end

  # --- Edge Cases ---
  describe 'Edge Cases' do
    context 'ohne gesetzten Tenant' do
      it 'verweigert den Zugriff auch für den Empfänger' do
        ActsAsTenant.current_tenant = nil
        expect(described_class.new(recipient, notification).show?).to be false
      end
    end

    context 'Notification mit archiviertem Status' do
      let(:archived_notification) do
        ActsAsTenant.with_tenant(organisation) do
          create(:notification, :archived, recipient: recipient, organisation: organisation)
        end
      end

      it 'erlaubt dem Empfänger weiterhin den Zugriff' do
        expect(described_class.new(recipient, archived_notification).show?).to be true
        expect(described_class.new(recipient, archived_notification).update?).to be true
      end
    end

    context 'Notification mit gelesenem Status' do
      let(:read_notification) do
        ActsAsTenant.with_tenant(organisation) do
          create(:notification, :read, recipient: recipient, organisation: organisation)
        end
      end

      it 'erlaubt mark_unread? für den Empfänger' do
        expect(described_class.new(recipient, read_notification).mark_unread?).to be true
      end

      it 'verweigert mark_unread? für fremde User' do
        expect(described_class.new(other_user, read_notification).mark_unread?).to be false
      end
    end

    context 'ApplicationPolicy Defaults (nicht explizit überschrieben)' do
      it 'verweigert create? (geerbt von ApplicationPolicy)' do
        expect(described_class.new(recipient, notification).create?).to be false
      end

      it 'delegiert new? an create?' do
        policy = described_class.new(recipient, notification)
        expect(policy.new?).to eq(policy.create?)
      end

      it 'delegiert edit? an update?' do
        policy = described_class.new(recipient, notification)
        expect(policy.edit?).to eq(policy.update?)
      end
    end
  end

  # --- Scope ---
  describe NotificationPolicy::Scope do
    let!(:own_notification) { notification }

    let!(:other_users_notification) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: other_user, organisation: organisation)
      end
    end

    let!(:other_org_notification) do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:notification, recipient: recipient, organisation: other_organisation)
      end
    end

    it 'gibt nur Notifications des aktuellen Users in der aktuellen Organisation zurück' do
      scope = described_class.new(recipient, Notification).resolve

      expect(scope).to include(own_notification)
      expect(scope).not_to include(other_users_notification)
      expect(scope).not_to include(other_org_notification)
    end

    # The unread badge (User#unread_notifications_count) filtered by project access from
    # the start, the inbox list under it did not. The number and the list disagreed for
    # anyone who had lost a project, and the list still showed the ticket titles.
    # The filter belongs in the scope, where nobody can forget to add it.
    context 'bei einem Projekt, das der User verloren hat' do
      let(:project) { create(:project, organisation: organisation) }
      let(:plain_role) { create(:role, organisation: organisation) }

      let!(:project_notification) do
        ActsAsTenant.with_tenant(organisation) do
          create(:notification, recipient: recipient, organisation: organisation, project: project)
        end
      end

      let!(:permission) do
        create(:project_permission, user: recipient, project: project, tickets_access: 'read_write')
      end

      before do
        create(:membership, user: recipient, organisation: organisation, role: plain_role, active: true)
      end

      it 'zeigt die Benachrichtigung, solange der Zugang besteht' do
        expect(described_class.new(recipient, Notification).resolve).to include(project_notification)
      end

      it 'blendet sie aus, sobald der Zugang weg ist' do
        permission.update!(tickets_access: 'no_access')

        expect(described_class.new(recipient, Notification).resolve).not_to include(project_notification)
      end

      it 'loescht sie dabei nicht, damit die Rueckkehr nichts reparieren muss' do
        permission.update!(tickets_access: 'no_access')

        expect(Notification.exists?(project_notification.id)).to be(true)
      end

      it 'zeigt sie wieder, sobald der Zugang zurueck ist' do
        permission.update!(tickets_access: 'no_access')
        permission.update!(tickets_access: 'read_write')

        expect(described_class.new(recipient, Notification).resolve).to include(project_notification)
      end
    end

    it 'gibt keine Notifications eines anderen Users zurück' do
      scope = described_class.new(other_user, Notification).resolve

      expect(scope).to include(other_users_notification)
      expect(scope).not_to include(own_notification)
    end

    it 'gibt leeres Ergebnis wenn User keine Notifications hat' do
      new_user = create(:user)
      scope = described_class.new(new_user, Notification).resolve

      expect(scope).to be_empty
    end

    it 'wirft Pundit::NotAuthorizedError ohne User' do
      expect { described_class.new(nil, Notification) }
        .to raise_error(Pundit::NotAuthorizedError, 'must be logged in')
    end
  end
end
