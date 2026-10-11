# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TimeSessionStatisticsPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }

  let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }
  let(:finance_role) { create(:role, title: 'Finance', organisation: organisation) }

  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  let(:standard_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
    user
  end

  let(:finance_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: finance_role, active: true)
    user
  end

  let(:non_member) { create(:user) }

  let(:inactive_member) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: false)
    user
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # Record is the organisation (authorize current_organisation, policy_class: ...)
  # =========================================================================
  # index? — admin or finance/accounting (aligned with TimeSessionGroupPolicy#index?)
  # =========================================================================
  describe '#index?' do
    it 'permits for admin' do
      expect(described_class.new(admin_user, organisation)).to permit_action(:index)
    end

    it 'permits for finance role' do
      expect(described_class.new(finance_user, organisation)).to permit_action(:index)
    end

    it 'denies for standard member' do
      expect(described_class.new(standard_user, organisation)).not_to permit_action(:index)
    end

    it 'denies for non-member' do
      expect(described_class.new(non_member, organisation)).not_to permit_action(:index)
    end

    it 'denies for inactive member' do
      expect(described_class.new(inactive_member, organisation)).not_to permit_action(:index)
    end
  end

  # =========================================================================
  # Inherited defaults — everything else is false
  # =========================================================================
  describe 'inherited defaults' do
    subject { described_class.new(admin_user, organisation) }

    it { is_expected.not_to permit_action(:show) }
    it { is_expected.not_to permit_action(:create) }
    it { is_expected.not_to permit_action(:update) }
    it { is_expected.not_to permit_action(:destroy) }
  end

  # =========================================================================
  # nil user
  # =========================================================================
  describe 'with nil user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect do
        described_class.new(nil, organisation)
      end.to raise_error(Pundit::NotAuthorizedError, 'must be logged in')
    end
  end
end
