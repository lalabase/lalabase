# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChangelogPolicy, :ci_guard, type: :policy do
  let(:user) { create(:user) }

  # =========================================================================
  # show? — every authenticated user may see the changelog
  # =========================================================================
  describe '#show?' do
    it 'permits for any authenticated user' do
      policy = described_class.new(user, :changelog)
      expect(policy.show?).to be true
    end
  end

  # =========================================================================
  # Headless policy: no ApplicationPolicy guard
  # =========================================================================
  describe 'headless policy structure' do
    it 'is a Struct, not an ApplicationPolicy subclass' do
      expect(described_class.superclass).not_to eq(ApplicationPolicy)
    end

    it 'does not raise on nil user (Devise guards authentication)' do
      policy = described_class.new(nil, :changelog)
      expect(policy.show?).to be true
    end
  end
end
