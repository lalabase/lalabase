# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatStylePreferencePolicy, :ci_guard do
  subject(:policy) { described_class.new(user, :chat_style_preference) }

  describe '#update?' do
    context 'with a logged-in user' do
      let(:user) { create(:user) }

      # Kills a `def update? = false` mutation; the real cross-user guard is the
      # controller's current_user scoping (covered in the request spec).
      it { expect(policy.update?).to be(true) }
    end

    context 'without a user' do
      let(:user) { nil }

      # ApplicationPolicy#initialize refuses a nil user outright.
      it 'cannot even be constructed' do
        expect { described_class.new(nil, :chat_style_preference) }.to raise_error(Pundit::NotAuthorizedError)
      end
    end
  end
end
