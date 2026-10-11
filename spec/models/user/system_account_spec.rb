# frozen_string_literal: true

# The "Lalabase" system account is the pseudo user acting as the ACTOR for
# system-generated activities (onboarding seed assignments). These specs pin
# its fence (doc/onboarding_plan.md, decision D2): it must exist exactly once,
# never authenticate, never appear as an org member, never be deletable and —
# critically — NOT carry is_ai (fanout_service.rb suppresses ALL notifications
# for is_ai actors, which would break the onboarding inbox chain).
require 'rails_helper'

RSpec.describe User::SystemAccount, type: :model do
  describe 'User.system' do
    it 'creates the system account on first call and reuses it afterwards' do
      expect { User.system }.to change(User, :count).by(1)
      expect { User.system }.not_to change(User, :count)
      expect(User.system.email).to eq(User::SystemAccount::EMAIL)
    end

    # Defense in depth: the singleton is guarded by the model validation AND
    # the partial unique DB index (email WHERE deleted_at IS NULL). Both layers
    # are tested separately — this one must stay red if someone drops the index
    # as "redundant". save!(validate: false) simulates the TOCTOU race without
    # flaky threads.
    it 'is unique at the DB layer even when the model validation is bypassed' do
      User.system
      racer = User.new(
        email: User::SystemAccount::EMAIL,
        first_name: 'Racer', last_name: 'Dup',
        password: 'password123'
      )
      expect { racer.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # The rescue branch of User.system: a concurrent double-create must
    # resolve to the existing row, never bubble the RecordNotUnique up into
    # the registration flow. Only the FIRST lookup is stubbed to miss (the
    # race window) — find_by! delegates to find_by internally, so the rescue's
    # re-read must hit the real implementation again.
    it 'recovers from a lost creation race by re-reading the existing account' do
      existing = User.system
      real_find_by = User.method(:find_by)
      first_lookup = true
      allow(User).to receive(:find_by) do |*args|
        if first_lookup
          first_lookup = false
          nil
        else
          real_find_by.call(*args)
        end
      end
      allow(User).to receive(:create_system_account!)
        .and_raise(ActiveRecord::RecordNotUnique, 'duplicate key')

      expect(User.system).to eq(existing)
    end

    it 'is not is_ai (is_ai actors suppress the whole notification fanout)' do
      expect(User.system.is_ai).to be(false)
    end

    it 'is inactive and access-locked' do
      system_user = User.system
      expect(system_user.active).to be(false)
      expect(system_user.access_locked?).to be(true)
    end
  end

  describe 'authentication fence' do
    it 'can never authenticate' do
      expect(User.system.active_for_authentication?).to be(false)
    end
  end

  describe 'membership fence' do
    it 'has no memberships and stays out of organisation user lists' do
      organisation = create(:organisation)
      ActsAsTenant.with_tenant(organisation) do
        system_user = User.system
        expect(system_user.memberships).to be_empty
        expect(organisation.users).not_to include(system_user)
        expect(organisation.active_users).not_to include(system_user)
      end
    end
  end

  describe 'deletion fence' do
    it 'refuses destroy and stays persisted' do
      system_user = User.system
      expect(system_user.destroy).to be(false)
      expect(system_user.reload).to be_persisted
    end

    it 'is excluded from the admin user listing scope' do
      User.system
      expect(Admin::User.without_system.pluck(:email)).not_to include(User::SystemAccount::EMAIL)
    end

    it 'refuses destroy through the tenant-bypassing Admin::User model too' do
      User.system
      admin_view = Admin::User.find_by!(email: User::SystemAccount::EMAIL)
      expect(admin_view.destroy).to be(false)
      expect(Admin::User.exists?(email: User::SystemAccount::EMAIL)).to be(true)
    end
  end
end
