# frozen_string_literal: true

require 'rails_helper'

# The admin backend's D4 hardening (per-request active-check, see
# Admin::Authentication#require_login) leans on ONE schema fact: `active`
# defaults to FALSE. That is exactly why the deploy prereq exists -- admin
# beusers created before the check was enforced must be reactivated by hand
# (doc/admin_account_owner_plan.md). If someone "helpfully" flips the default to
# TRUE, the lockout risk silently disappears AND this contract test breaks first.
RSpec.describe Beuser, type: :model do
  describe 'schema defaults (the contract behind the D4 deploy prereq)' do
    # NOT via the :beuser factory (which sets active: true) -- assert the DB
    # default itself, so a changed migration default is what fails here.
    it 'defaults active to false when the column is omitted on insert' do
      beuser = described_class.create!(email: 'fresh-default@example.com', password: 'beuser-password-123')

      expect(beuser.reload.active).to be false
    end

    it 'defaults role to "user", so a freshly created beuser is NOT an admin' do
      beuser = described_class.create!(email: 'fresh-role@example.com', password: 'beuser-password-123')

      expect(beuser.reload.role).to eq('user')
      expect(beuser.admin?).to be false
    end
  end

  describe '#admin?' do
    it 'is true only for the admin role' do
      expect(build(:beuser, role: 'admin').admin?).to be true
      expect(build(:beuser, role: 'user').admin?).to be false
    end
  end

  describe 'password length' do
    let(:floor) { Devise.password_length.min }

    it 'refuses a password one character below the Devise floor' do
      beuser = build(:beuser, password: 'x' * (floor - 1))

      expect(beuser).not_to be_valid
      expect(beuser.errors[:password]).to be_present
    end

    it 'accepts a password at the floor' do
      expect(build(:beuser, password: 'x' * floor)).to be_valid
    end

    it 'refuses a short new password set through set_new_password' do
      beuser = create(:beuser)
      beuser.set_new_password('short', 'short')

      expect(beuser.save).to be(false)
    end

    it 'keeps an update without a password valid' do
      beuser = described_class.find(create(:beuser).id)

      expect(beuser.update(firstname: 'Renamed')).to be(true)
    end
  end

  describe 'the last active admin' do
    let!(:admin) { create(:beuser) }

    it 'cannot demote itself' do
      expect(admin.update(role: 'user')).to be(false)
      expect(admin.errors[:base]).to include(I18n.t('activerecord.errors.models.beuser.last_active_admin'))
    end

    it 'cannot deactivate itself' do
      expect(admin.update(active: false)).to be(false)
    end

    it 'can be demoted once another active admin exists' do
      create(:beuser)

      expect(admin.update(role: 'user')).to be(true)
    end

    it 'does not count an inactive admin as the other one' do
      create(:beuser, active: false)

      expect(admin.update(role: 'user')).to be(false)
    end

    it 'does not block changes to a beuser that was no active admin' do
      user = create(:beuser, role: 'user')

      expect(user.update(active: false)).to be(true)
    end

    it 'cannot be destroyed' do
      expect(admin.destroy).to be(false)
      expect(admin.errors[:base]).to include(I18n.t('activerecord.errors.models.beuser.last_active_admin'))
      expect(described_class.exists?(admin.id)).to be(true)
    end

    it 'can be destroyed once another active admin exists' do
      create(:beuser)

      expect(admin.destroy).to be_truthy
    end

    # Two admins demoting each other at once would each still see the other one
    # as active. The check holds a transaction-scoped lock until commit, so the
    # second check waits and then sees the first write.
    it 'holds the lock until the demotion commits' do
      create(:beuser)
      advisory_locks = lambda do
        described_class.connection.select_value("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()")
      end

      described_class.transaction do
        expect(advisory_locks.call).to eq(0)
        admin.update!(role: 'user')
        expect(advisory_locks.call).to eq(1)
      end
    end
  end
end
