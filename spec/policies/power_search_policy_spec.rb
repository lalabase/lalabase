# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PowerSearchPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  let(:user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
    user
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # ── Struct-based policy (not ApplicationPolicy) ─────────────────────

  describe 'policy structure' do
    it 'is a Struct, not an ApplicationPolicy subclass' do
      expect(described_class.superclass).not_to eq(ApplicationPolicy)
    end

    it 'does not raise Pundit::NotAuthorizedError for nil user' do
      policy = described_class.new(nil, :power_search)
      expect { policy.index? }.not_to raise_error
    end
  end

  # ── nil user ────────────────────────────────────────────────────────

  describe 'with nil user' do
    subject { described_class.new(nil, :power_search) }

    it 'denies index' do
      expect(subject.index?).to be false
    end

    it 'denies execute' do
      expect(subject.execute?).to be false
    end
  end

  # ── Authenticated user ──────────────────────────────────────────────

  describe 'for authenticated users' do
    subject { described_class.new(user, :power_search) }

    it 'permits index' do
      expect(subject.index?).to be true
    end

    it 'permits execute' do
      expect(subject.execute?).to be true
    end
  end

  # ── No further actions defined ──────────────────────────────────────

  describe 'undefined actions' do
    subject { described_class.new(user, :power_search) }

    it 'raises NoMethodError for show?' do
      expect { subject.show? }.to raise_error(NoMethodError)
    end

    it 'raises NoMethodError for create?' do
      expect { subject.create? }.to raise_error(NoMethodError)
    end

    it 'raises NoMethodError for destroy?' do
      expect { subject.destroy? }.to raise_error(NoMethodError)
    end
  end
end
