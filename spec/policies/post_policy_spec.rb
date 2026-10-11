# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }

  let(:admin_role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:role, title: 'account_admin', organisation: organisation)
    end
  end

  let(:reader_role) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: 'Ticket-Leser', organisation: organisation)
      create(:project_read_permission, role: role, area: 'tickets')
      role
    end
  end

  let(:writer_role) do
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: 'Ticket-Schreiber', organisation: organisation)
      create(:project_read_permission, role: role, area: 'tickets')
      create(:project_write_permission, role: role, area: 'tickets')
      role
    end
  end

  let(:no_access_role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:role, title: 'Ohne-Zugriff', organisation: organisation)
    end
  end

  let(:admin_user) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
    user
  end

  let(:reader_user) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: reader_role, active: true)
    end
    user
  end

  let(:writer_user) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: writer_role, active: true)
    end
    user
  end

  let(:no_access_user) do
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: no_access_role, active: true)
    end
    user
  end

  let(:unaffiliated_user) { create(:user) }

  let(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end

  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: writer_user)
    end
  end

  let(:public_post) do
    ActsAsTenant.with_tenant(organisation) do
      create(:post, ticket: ticket, user: writer_user, organisation: organisation, is_private: false)
    end
  end

  let(:private_post) do
    ActsAsTenant.with_tenant(organisation) do
      create(:post, ticket: ticket, user: writer_user, organisation: organisation,
                    is_private: true, visible_to_user: writer_user)
    end
  end

  let(:private_post_for_reader) do
    ActsAsTenant.with_tenant(organisation) do
      create(:post, ticket: ticket, user: writer_user, organisation: organisation,
                    is_private: true, visible_to_user: reader_user)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # ---------------------------------------------------------------------------
  # show?
  # ---------------------------------------------------------------------------
  describe '#show?' do
    context 'öffentliche Posts' do
      it 'erlaubt Admin den Zugriff' do
        expect(described_class.new(admin_user, public_post).show?).to be true
      end

      it 'erlaubt User mit Ticket-Leserecht den Zugriff' do
        expect(described_class.new(reader_user, public_post).show?).to be true
      end

      it 'erlaubt User mit Ticket-Schreibrecht den Zugriff' do
        expect(described_class.new(writer_user, public_post).show?).to be true
      end

      it 'verweigert User ohne Projekt-Zugriff' do
        expect(described_class.new(no_access_user, public_post).show?).to be_falsey
      end

      it 'verweigert User ohne Membership' do
        expect(described_class.new(unaffiliated_user, public_post).show?).to be_falsey
      end
    end

    context 'private Posts' do
      it 'erlaubt Admin den Zugriff (bypassed Private-Check)' do
        expect(described_class.new(admin_user, private_post).show?).to be true
      end

      it 'erlaubt dem visible_to_user den Zugriff' do
        expect(described_class.new(writer_user, private_post).show?).to be true
      end

      it 'verweigert anderem User mit Leserecht den Zugriff auf fremden privaten Post' do
        expect(described_class.new(reader_user, private_post).show?).to be false
      end

      it 'erlaubt dem visible_to_user eines an ihn gerichteten privaten Posts den Zugriff' do
        expect(described_class.new(reader_user, private_post_for_reader).show?).to be true
      end

      it 'verweigert User ohne Projekt-Zugriff auch bei privaten Posts' do
        expect(described_class.new(no_access_user, private_post).show?).to be_falsey
      end
    end
  end

  # ---------------------------------------------------------------------------
  # create?
  # ---------------------------------------------------------------------------
  describe '#create?' do
    it 'erlaubt Admin das Erstellen' do
      expect(described_class.new(admin_user, public_post).create?).to be true
    end

    it 'erlaubt User mit Schreibrecht das Erstellen' do
      expect(described_class.new(writer_user, public_post).create?).to be true
    end

    it 'verweigert User mit nur Leserecht das Erstellen' do
      expect(described_class.new(reader_user, public_post).create?).to be_falsey
    end

    it 'verweigert User ohne Projekt-Zugriff das Erstellen' do
      expect(described_class.new(no_access_user, public_post).create?).to be_falsey
    end

    it 'verweigert User ohne Membership das Erstellen' do
      expect(described_class.new(unaffiliated_user, public_post).create?).to be_falsey
    end
  end

  describe '#react?' do
    it 'erlaubt einem Writer die Reaktion auf einen sichtbaren Post' do
      expect(described_class.new(writer_user, public_post).react?).to be true
    end

    it 'verweigert einem Reader die Reaktion' do
      expect(described_class.new(reader_user, public_post).react?).to be false
    end

    it 'verweigert die Reaktion auf einen nicht sichtbaren privaten Post' do
      expect(described_class.new(reader_user, private_post).react?).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # update?
  # ---------------------------------------------------------------------------
  describe '#update?' do
    context 'eigene Posts' do
      it 'erlaubt Admin das Bearbeiten' do
        expect(described_class.new(admin_user, public_post).update?).to be true
      end

      it 'erlaubt dem Autor mit Schreibrecht das Bearbeiten' do
        expect(described_class.new(writer_user, public_post).update?).to be true
      end
    end

    context 'fremde Posts' do
      let(:other_writer) do
        user = create(:user)
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation, role: writer_role, active: true)
        end
        user
      end

      it 'erlaubt Admin das Bearbeiten fremder Posts' do
        expect(described_class.new(admin_user, public_post).update?).to be true
      end

      it 'verweigert anderem Writer das Bearbeiten fremder Posts' do
        expect(described_class.new(other_writer, public_post).update?).to be false
      end
    end

    it 'verweigert User mit nur Leserecht das Bearbeiten eigener Posts' do
      reader_post = ActsAsTenant.with_tenant(organisation) do
        create(:post, ticket: ticket, user: reader_user, organisation: organisation)
      end
      expect(described_class.new(reader_user, reader_post).update?).to be_falsey
    end

    it 'verweigert User ohne Projekt-Zugriff' do
      expect(described_class.new(no_access_user, public_post).update?).to be_falsey
    end

    it 'verweigert User ohne Membership' do
      expect(described_class.new(unaffiliated_user, public_post).update?).to be_falsey
    end
  end

  # ---------------------------------------------------------------------------
  # destroy?
  # ---------------------------------------------------------------------------
  describe '#destroy?' do
    context 'eigene Posts' do
      it 'erlaubt Admin das Löschen' do
        expect(described_class.new(admin_user, public_post).destroy?).to be true
      end

      it 'erlaubt dem Autor mit Schreibrecht das Löschen' do
        expect(described_class.new(writer_user, public_post).destroy?).to be true
      end
    end

    context 'fremde Posts' do
      let(:other_writer) do
        user = create(:user)
        ActsAsTenant.with_tenant(organisation) do
          create(:membership, user: user, organisation: organisation, role: writer_role, active: true)
        end
        user
      end

      it 'erlaubt Admin das Löschen fremder Posts' do
        expect(described_class.new(admin_user, public_post).destroy?).to be true
      end

      it 'verweigert anderem Writer das Löschen fremder Posts' do
        expect(described_class.new(other_writer, public_post).destroy?).to be false
      end
    end

    it 'verweigert User mit nur Leserecht das Löschen' do
      expect(described_class.new(reader_user, public_post).destroy?).to be_falsey
    end

    it 'verweigert User ohne Projekt-Zugriff' do
      expect(described_class.new(no_access_user, public_post).destroy?).to be_falsey
    end

    it 'verweigert User ohne Membership' do
      expect(described_class.new(unaffiliated_user, public_post).destroy?).to be_falsey
    end
  end

  # ---------------------------------------------------------------------------
  # edit? delegates to update?
  # ---------------------------------------------------------------------------
  describe '#edit?' do
    it 'delegiert an update?' do
      policy = described_class.new(writer_user, public_post)
      expect(policy.edit?).to eq(policy.update?)
    end
  end

  # ---------------------------------------------------------------------------
  # index? — not overridden, inherits false from ApplicationPolicy
  # ---------------------------------------------------------------------------
  describe '#index?' do
    it 'verweigert selbst Admin-Usern (nicht überschrieben)' do
      expect(described_class.new(admin_user, public_post).index?).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Scope
  # ---------------------------------------------------------------------------
  describe PostPolicy::Scope do
    let!(:public_post_record) { public_post }
    let!(:private_post_record) { private_post }
    let!(:private_post_for_reader_record) { private_post_for_reader }

    context 'als Admin' do
      it 'gibt alle Posts zurück (auch private)' do
        scope = described_class.new(admin_user, Post).resolve
        expect(scope).to include(public_post_record, private_post_record, private_post_for_reader_record)
      end
    end

    context 'als User mit Leserecht' do
      it 'gibt öffentliche Posts zurück' do
        scope = described_class.new(reader_user, Post).resolve
        expect(scope).to include(public_post_record)
      end

      it 'gibt private Posts zurück, die an den User gerichtet sind' do
        scope = described_class.new(reader_user, Post).resolve
        expect(scope).to include(private_post_for_reader_record)
      end

      it 'filtert private Posts, die nicht an den User gerichtet sind' do
        scope = described_class.new(reader_user, Post).resolve
        expect(scope).not_to include(private_post_record)
      end
    end

    context 'als User ohne Projekt-Zugriff' do
      it 'gibt keine Posts zurück' do
        scope = described_class.new(no_access_user, Post).resolve
        expect(scope).to be_empty
      end
    end
  end
end
