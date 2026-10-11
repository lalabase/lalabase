# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InvitationPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation) }

  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role)
    user
  end

  let(:member_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: member_role)
    user
  end

  let(:unaffiliated_user) { create(:user) }

  let(:other_org_admin) do
    user = create(:user)
    other_admin_role = create(:admin_role, organisation: other_organisation)
    create(:membership, user: user, organisation: other_organisation, role: other_admin_role)
    user
  end

  let(:invitation) do
    ActsAsTenant.with_tenant(organisation) do
      create(:invitation, organisation: organisation)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # ---------------------------------------------------------------------------
  # index?
  # ---------------------------------------------------------------------------
  describe '#index?' do
    it 'erlaubt Admin-Usern den Zugriff' do
      expect(described_class.new(admin_user, invitation).index?).to be true
    end

    it 'erlaubt Member-Usern den Zugriff' do
      expect(described_class.new(member_user, invitation).index?).to be true
    end

    it 'erlaubt Usern ohne Membership den Zugriff' do
      expect(described_class.new(unaffiliated_user, invitation).index?).to be true
    end

    it 'wirft Pundit::NotAuthorizedError wenn kein User übergeben wird' do
      expect { described_class.new(nil, invitation) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  # ---------------------------------------------------------------------------
  # show?
  # ---------------------------------------------------------------------------
  describe '#show?' do
    it 'erlaubt Admin-Usern den Zugriff' do
      expect(described_class.new(admin_user, invitation).show?).to be true
    end

    it 'verweigert Member-Usern den Zugriff' do
      expect(described_class.new(member_user, invitation).show?).to be false
    end

    it 'verweigert Usern ohne Membership den Zugriff' do
      expect(described_class.new(unaffiliated_user, invitation).show?).to be false
    end

    it 'verweigert Admin einer anderen Organisation den Zugriff' do
      expect(described_class.new(other_org_admin, invitation).show?).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # new? / create?
  # ---------------------------------------------------------------------------
  describe '#create?' do
    it 'erlaubt Admin-Usern das Erstellen' do
      expect(described_class.new(admin_user, invitation).create?).to be true
    end

    it 'verweigert Member-Usern das Erstellen' do
      expect(described_class.new(member_user, invitation).create?).to be false
    end

    it 'verweigert Usern ohne Membership das Erstellen' do
      expect(described_class.new(unaffiliated_user, invitation).create?).to be false
    end

    it 'verweigert Admin einer anderen Organisation das Erstellen' do
      expect(described_class.new(other_org_admin, invitation).create?).to be false
    end
  end

  describe '#new?' do
    it 'delegiert an create?' do
      policy = described_class.new(admin_user, invitation)
      expect(policy.new?).to eq(policy.create?)
    end

    it 'verweigert Nicht-Admins' do
      policy = described_class.new(member_user, invitation)
      expect(policy.new?).to eq(policy.create?)
      expect(policy.new?).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # destroy?
  # ---------------------------------------------------------------------------
  describe '#destroy?' do
    it 'erlaubt Admin-Usern das Löschen' do
      expect(described_class.new(admin_user, invitation).destroy?).to be true
    end

    it 'verweigert Member-Usern das Löschen' do
      expect(described_class.new(member_user, invitation).destroy?).to be false
    end

    it 'verweigert Usern ohne Membership das Löschen' do
      expect(described_class.new(unaffiliated_user, invitation).destroy?).to be false
    end

    it 'verweigert Admin einer anderen Organisation das Löschen' do
      expect(described_class.new(other_org_admin, invitation).destroy?).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # update? / edit? — not overridden, should be false
  # ---------------------------------------------------------------------------
  describe '#update?' do
    it 'verweigert selbst Admin-Usern (nicht implementiert)' do
      expect(described_class.new(admin_user, invitation).update?).to be false
    end
  end

  describe '#edit?' do
    it 'verweigert selbst Admin-Usern (nicht implementiert)' do
      expect(described_class.new(admin_user, invitation).edit?).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Edge Cases: Organisation-Fallback in user_is_admin_in_organisation?
  # ---------------------------------------------------------------------------
  describe 'Organisation-Fallback Logik' do
    context 'wenn record.organisation nil ist (neuer Record)' do
      let(:new_invitation) { Invitation.new(organisation: nil) }

      it 'fällt auf den Tenant zurück und erlaubt Admin Zugriff' do
        expect(described_class.new(admin_user, new_invitation).create?).to be true
      end

      it 'fällt auf den Tenant zurück und verweigert Nicht-Admin Zugriff' do
        expect(described_class.new(member_user, new_invitation).create?).to be false
      end
    end

    context 'wenn weder record.organisation noch Tenant gesetzt ist' do
      it 'verweigert den Zugriff (kein Org-Kontext)' do
        # Create records in the tenant context first, then remove the tenant
        admin = admin_user
        new_invitation = Invitation.new(organisation: nil)
        ActsAsTenant.current_tenant = nil

        expect(described_class.new(admin, new_invitation).create?).to be false
      end
    end

    context 'wenn record einer anderen Organisation gehört' do
      let(:other_org_invitation) do
        ActsAsTenant.with_tenant(other_organisation) do
          create(:invitation, organisation: other_organisation)
        end
      end

      it 'prüft gegen die Organisation des Records, nicht den Tenant' do
        # Admin in organisation, but invitation belongs to other_organisation
        expect(described_class.new(admin_user, other_org_invitation).show?).to be false
      end

      it 'erlaubt Admin der Record-Organisation den Zugriff' do
        expect(described_class.new(other_org_admin, other_org_invitation).show?).to be true
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scope
  # ---------------------------------------------------------------------------
  describe InvitationPolicy::Scope do
    let!(:own_invitation) { invitation }
    let!(:other_org_invitation) do
      ActsAsTenant.with_tenant(other_organisation) do
        create(:invitation, organisation: other_organisation)
      end
    end

    describe '#resolve' do
      context 'als Admin der Organisation' do
        it 'gibt nur Einladungen der aktuellen Organisation zurück' do
          scope = described_class.new(admin_user, Invitation).resolve
          expect(scope).to include(own_invitation)
          expect(scope).not_to include(other_org_invitation)
        end
      end

      context 'als Member (kein Admin)' do
        it 'gibt keine Einladungen zurück' do
          scope = described_class.new(member_user, Invitation).resolve
          expect(scope).to be_empty
        end
      end

      context 'als User ohne Membership' do
        it 'gibt keine Einladungen zurück' do
          scope = described_class.new(unaffiliated_user, Invitation).resolve
          expect(scope).to be_empty
        end
      end

      context 'als Admin einer anderen Organisation' do
        it 'gibt keine Einladungen zurück (falscher Tenant)' do
          scope = described_class.new(other_org_admin, Invitation).resolve
          expect(scope).to be_empty
        end
      end

      context 'ohne gesetzten Tenant' do
        it 'gibt keine Einladungen zurück' do
          admin = admin_user
          ActsAsTenant.current_tenant = nil

          scope = described_class.new(admin, Invitation).resolve
          expect(scope).to be_empty
        end
      end
    end
  end
end
