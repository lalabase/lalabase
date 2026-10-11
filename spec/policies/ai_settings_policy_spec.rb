# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AiSettingsPolicy, :ci_guard, type: :policy do
  subject { described_class }

  let(:organisation) { create(:organisation) }
  let(:admin_role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:role, title: 'account_admin', organisation: organisation)
    end
  end
  let(:user_role) do
    ActsAsTenant.with_tenant(organisation) do
      create(:role, title: 'Standard-Benutzer', organisation: organisation, is_default: true)
    end
  end

  let(:admin_user) { create(:user) }
  let(:regular_user) { create(:user) }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin_user, organisation: organisation, role: admin_role, active: true)
    end
  end
  let!(:user_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: regular_user, organisation: organisation, role: user_role, active: true)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'show?' do
    context 'when user is account admin' do
      it 'grants access' do
        policy = described_class.new(admin_user, organisation)
        expect(policy.show?).to be_truthy
      end
    end

    context 'when user is regular user' do
      it 'denies access' do
        policy = described_class.new(regular_user, organisation)
        expect(policy.show?).to be_falsey
      end
    end
  end

  describe 'update?' do
    context 'when user is account admin' do
      it 'grants access' do
        policy = described_class.new(admin_user, organisation)
        expect(policy.update?).to be_truthy
      end
    end

    context 'when user is regular user' do
      it 'denies access' do
        policy = described_class.new(regular_user, organisation)
        expect(policy.update?).to be_falsey
      end
    end
  end

  describe 'test_connection?' do
    context 'when user is account admin' do
      it 'grants access' do
        policy = described_class.new(admin_user, organisation)
        expect(policy.test_connection?).to be_truthy
      end
    end

    context 'when user is regular user' do
      it 'denies access' do
        policy = described_class.new(regular_user, organisation)
        expect(policy.test_connection?).to be_falsey
      end
    end
  end

  # GDPR AI opt-in (audit 2026-07-03): flipping the switch IS the legal-basis
  # documentation, so both directions are admin-only. Positive AND negative per
  # action — a `= true` mutation on either policy method dies here.
  %w[activate? deactivate?].each do |action|
    describe action do
      it 'grants access to account admins' do
        policy = described_class.new(admin_user, organisation)
        expect(policy.public_send(action)).to be_truthy
      end

      it 'denies access to regular users' do
        policy = described_class.new(regular_user, organisation)
        expect(policy.public_send(action)).to be_falsey
      end
    end
  end

  describe 'Scope' do
    subject { described_class::Scope.new(user, Organisation).resolve }

    context 'when user is account admin' do
      let(:user) { admin_user }

      it 'returns the current organisation' do
        expect(subject).to contain_exactly(organisation)
      end
    end

    context 'when user is regular user' do
      let(:user) { regular_user }

      it 'returns empty collection' do
        expect(subject).to be_empty
      end
    end
  end
end
