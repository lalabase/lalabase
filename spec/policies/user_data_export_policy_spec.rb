# frozen_string_literal: true

require 'rails_helper'

# The policy is deliberately permissive on show/create (data-subject right,
# never org-role-gated) and strict on download (owner only). These tests pin
# both directions: loosening download? OR tightening show?/create? goes red.
RSpec.describe UserDataExportPolicy, :ci_guard do
  let(:user) { create(:user) }

  it 'refuses unauthenticated access entirely (ApplicationPolicy contract)' do
    expect { described_class.new(nil, UserDataExport) }
      .to raise_error(Pundit::NotAuthorizedError)
  end

  it 'allows show and create for every signed-in user — no org role required' do
    policy = described_class.new(user, UserDataExport)

    expect(policy.show?).to be(true)
    expect(policy.create?).to be(true)
  end

  describe '#download?' do
    it 'allows the owner' do
      export = create(:user_data_export, user: user)
      expect(described_class.new(user, export).download?).to be(true)
    end

    it 'refuses any other user' do
      export = create(:user_data_export, user: create(:user))
      expect(described_class.new(user, export).download?).to be(false)
    end
  end
end
