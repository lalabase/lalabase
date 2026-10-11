# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }

  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation) }

  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  let(:member_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: member_role, active: true)
    user
  end

  let(:unaffiliated_user) { create(:user) }

  let(:record) { double('Record') }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # ---------------------------------------------------------------------------
  # initialize
  # ---------------------------------------------------------------------------
  describe '#initialize' do
    it 'setzt user, record und organisation' do
      policy = described_class.new(admin_user, record)
      expect(policy.user).to eq(admin_user)
      expect(policy.record).to eq(record)
      expect(policy.organisation).to eq(organisation)
    end

    it 'wirft Pundit::NotAuthorizedError bei nil User' do
      expect { described_class.new(nil, record) }.to raise_error(
        Pundit::NotAuthorizedError, 'must be logged in'
      )
    end

    it 'erlaubt nil record' do
      policy = described_class.new(admin_user, nil)
      expect(policy.record).to be_nil
    end

    it 'setzt organisation aus ActsAsTenant.current_tenant' do
      policy = described_class.new(admin_user, record)
      expect(policy.organisation).to eq(ActsAsTenant.current_tenant)
    end

    it 'setzt organisation auf nil wenn kein Tenant gesetzt' do
      user = member_user # eager-load before removing the tenant (member_role does not trigger a tenant problem)
      ActsAsTenant.current_tenant = nil
      policy = described_class.new(user, record)
      expect(policy.organisation).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Default actions — all false
  # ---------------------------------------------------------------------------
  describe 'Default-Aktionen' do
    subject { described_class.new(admin_user, record) }

    it 'verweigert index?' do
      expect(subject.index?).to be false
    end

    it 'verweigert show?' do
      expect(subject.show?).to be false
    end

    it 'verweigert create?' do
      expect(subject.create?).to be false
    end

    it 'verweigert update?' do
      expect(subject.update?).to be false
    end

    it 'verweigert destroy?' do
      expect(subject.destroy?).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Delegations
  # ---------------------------------------------------------------------------
  describe 'Delegationen' do
    subject { described_class.new(admin_user, record) }

    it 'new? delegiert an create?' do
      expect(subject.new?).to eq(subject.create?)
    end

    it 'edit? delegiert an update?' do
      expect(subject.edit?).to eq(subject.update?)
    end
  end

  # ---------------------------------------------------------------------------
  # Protected Helper: account_admin?
  # ---------------------------------------------------------------------------
  describe '#account_admin?' do
    it 'gibt true für Admin-User zurück' do
      policy = described_class.new(admin_user, record)
      expect(policy.send(:account_admin?)).to be true
    end

    it 'gibt false für Member-User zurück (nicht nil)' do
      policy = described_class.new(member_user, record)
      expect(policy.send(:account_admin?)).to be false
    end

    it 'gibt falsey für User ohne Membership zurück' do
      policy = described_class.new(unaffiliated_user, record)
      expect(policy.send(:account_admin?)).to be_falsey
    end

    it 'gibt falsey zurück wenn kein Tenant gesetzt ist' do
      user = member_user # eager-load before removing the tenant
      ActsAsTenant.current_tenant = nil
      policy = described_class.new(user, record)
      expect(policy.send(:account_admin?)).to be_falsey
    end
  end

  # ---------------------------------------------------------------------------
  # Protected Helper: has_permission?
  # ---------------------------------------------------------------------------
  describe '#has_permission?' do
    before do
      create(:permission, role: member_role, category: 'projects',
                          action: 'create_new_projects', allowed: true)
    end

    it 'gibt true zurück wenn Berechtigung vorhanden' do
      policy = described_class.new(member_user, record)
      expect(policy.send(:has_permission?, 'projects', 'create_new_projects')).to be true
    end

    it 'gibt false zurück wenn Berechtigung fehlt (nicht nil)' do
      policy = described_class.new(member_user, record)
      expect(policy.send(:has_permission?, 'projects', 'delete_projects')).to be false
    end

    it 'gibt false zurück für User ohne Membership' do
      policy = described_class.new(unaffiliated_user, record)
      expect(policy.send(:has_permission?, 'projects', 'create_new_projects')).to be false
    end

    it 'gibt false zurück wenn kein Tenant gesetzt ist' do
      ActsAsTenant.current_tenant = nil
      policy = described_class.new(member_user, record)
      expect(policy.send(:has_permission?, 'projects', 'create_new_projects')).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Scope
  # ---------------------------------------------------------------------------
  describe ApplicationPolicy::Scope do
    describe '#initialize' do
      it 'setzt user, scope und organisation' do
        scope = described_class.new(admin_user, double('Scope'))
        expect(scope.send(:user)).to eq(admin_user)
        expect(scope.send(:organisation)).to eq(organisation)
      end

      it 'wirft Pundit::NotAuthorizedError bei nil User' do
        expect { described_class.new(nil, double('Scope')) }.to raise_error(
          Pundit::NotAuthorizedError, 'must be logged in'
        )
      end
    end

    describe '#resolve' do
      it 'wirft NotImplementedError' do
        scope = described_class.new(admin_user, double('Scope'))
        expect { scope.resolve }.to raise_error(
          NotImplementedError, /You must define #resolve/
        )
      end
    end
  end
end
