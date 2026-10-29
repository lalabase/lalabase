# frozen_string_literal: true

# == Schema Information
#
# Table name: users
#
#  id                      :uuid             not null, primary key
#  active                  :boolean          default(TRUE), not null
#  changelog_last_read_at  :datetime
#  confirmation_sent_at    :datetime
#  confirmation_token      :string
#  confirmed_at            :datetime
#  deleted_at              :datetime
#  deletion_canceled_at    :datetime
#  deletion_reason         :text
#  deletion_recommended    :boolean          default(FALSE), not null
#  email                   :string           default(""), not null
#  encrypted_password      :string           default(""), not null
#  failed_attempts         :integer          default(0), not null
#  first_name              :string
#  is_ai                   :boolean          default(FALSE)
#  language_preference     :string           default("de"), not null
#  last_name               :string
#  last_seen_at            :datetime
#  locked_at               :datetime
#  preferences             :jsonb            not null
#  remember_created_at     :datetime
#  reset_password_sent_at  :datetime
#  reset_password_token    :string
#  scheduled_deletion_at   :datetime
#  session_timeout_minutes :integer          default(30), not null
#  terms_accepted_at       :datetime
#  timezone                :string           default("Europe/Berlin")
#  unconfirmed_email       :string
#  unlock_token            :string
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  invited_by_org_id       :uuid
#  invited_by_user_id      :uuid
#
# Indexes
#
#  index_users_on_confirmation_token     (confirmation_token) UNIQUE
#  index_users_on_deleted_at             (deleted_at)
#  index_users_on_deletion_recommended   (deletion_recommended)
#  index_users_on_email_active           (email) UNIQUE WHERE (deleted_at IS NULL)
#  index_users_on_invited_by_org_id      (invited_by_org_id)
#  index_users_on_invited_by_user_id     (invited_by_user_id)
#  index_users_on_language_preference    (language_preference)
#  index_users_on_last_seen_at           (last_seen_at)
#  index_users_on_preferences            (preferences) USING gin
#  index_users_on_scheduled_deletion_at  (scheduled_deletion_at)
#  index_users_on_timezone               (timezone)
#  index_users_on_unlock_token           (unlock_token) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (invited_by_org_id => organisations.id)
#  fk_rails_...  (invited_by_user_id => users.id)
#
require 'rails_helper'

RSpec.describe Admin::User, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  # Helper to create memberships without acts_as_tenant interference
  def create_admin_membership(user:, organisation:, **attrs)
    role = attrs.delete(:role)
    unless role
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, organisation: organisation)
      end
    end
    Admin::Membership.create!(
      user_id: user.id,
      organisation_id: organisation.id,
      role_id: role&.id,
      active: attrs.fetch(:active, true)
    )
  end

  describe 'table configuration' do
    it 'uses the users table' do
      expect(described_class.table_name).to eq('users')
    end

    it 'has a custom model_name without Admin namespace' do
      expect(described_class.model_name.name).to eq('User')
      expect(described_class.model_name.singular).to eq('user')
      expect(described_class.model_name.plural).to eq('users')
    end
  end

  describe 'validations' do
    subject(:user) { build(:admin_user) }

    it 'is valid with valid attributes' do
      expect(user).to be_valid
    end

    describe 'email' do
      it 'requires email' do
        user.email = nil
        expect(user).not_to be_valid
        expect(user.errors[:email]).to be_present
      end

      it 'requires email to be non-blank' do
        user.email = ''
        expect(user).not_to be_valid
      end

      it 'requires unique email' do
        create(:admin_user, email: 'duplicate@example.com')
        user.email = 'duplicate@example.com'
        expect(user).not_to be_valid
        expect(user.errors[:email]).to be_present
      end
    end

    describe 'first_name' do
      it 'requires first_name' do
        user.first_name = nil
        expect(user).not_to be_valid
        expect(user.errors[:first_name]).to be_present
      end

      it 'requires first_name to be non-blank' do
        user.first_name = ''
        expect(user).not_to be_valid
      end
    end

    describe 'last_name' do
      it 'requires last_name' do
        user.last_name = nil
        expect(user).not_to be_valid
        expect(user.errors[:last_name]).to be_present
      end

      it 'requires last_name to be non-blank' do
        user.last_name = ''
        expect(user).not_to be_valid
      end
    end

    describe 'active' do
      it 'accepts true' do
        user.active = true
        expect(user).to be_valid
      end

      it 'accepts false' do
        user.active = false
        expect(user).to be_valid
      end

      it 'rejects nil' do
        user.active = nil
        expect(user).not_to be_valid
        expect(user.errors[:active]).to be_present
      end
    end
  end

  describe 'associations' do
    it 'has many memberships (Admin::Membership)' do
      assoc = described_class.reflect_on_association(:memberships)
      expect(assoc.macro).to eq(:has_many)
      expect(assoc.options[:class_name]).to eq('Admin::Membership')
      expect(assoc.options[:dependent]).to eq(:destroy)
    end

    it 'has many organisations through memberships' do
      assoc = described_class.reflect_on_association(:organisations)
      expect(assoc.macro).to eq(:has_many)
      expect(assoc.options[:through]).to eq(:memberships)
    end

    it 'has many project_permissions (Admin::ProjectPermission)' do
      assoc = described_class.reflect_on_association(:project_permissions)
      expect(assoc.macro).to eq(:has_many)
      expect(assoc.options[:class_name]).to eq('Admin::ProjectPermission')
      expect(assoc.options[:dependent]).to eq(:destroy)
    end

    it 'has many permitted_projects through project_permissions' do
      assoc = described_class.reflect_on_association(:permitted_projects)
      expect(assoc.macro).to eq(:has_many)
      expect(assoc.options[:through]).to eq(:project_permissions)
      expect(assoc.options[:source]).to eq(:project)
    end
  end

  describe 'callbacks' do
    describe 'encrypt_password_if_present' do
      it 'encrypts password with BCrypt on save' do
        user = build(:admin_user, password: 'secure_password')
        user.save!
        expect(user.encrypted_password).to be_present
        expect(::BCrypt::Password.new(user.encrypted_password)).to eq('secure_password')
      end

      it 'does not change encrypted_password when password is nil' do
        user = create(:admin_user)
        original_encrypted = user.encrypted_password
        user.password = nil
        user.first_name = 'Updated'
        user.save!
        expect(user.encrypted_password).to eq(original_encrypted)
      end

      it 'does not change encrypted_password when password is blank' do
        user = create(:admin_user, password: 'initial')
        original_encrypted = user.encrypted_password
        user.password = ''
        user.first_name = 'Updated'
        user.save!
        expect(user.encrypted_password).to eq(original_encrypted)
      end

      it 'updates encrypted_password when password changes' do
        user = create(:admin_user, password: 'old_password')
        old_encrypted = user.encrypted_password
        user.password = 'new_password'
        user.save!
        expect(user.encrypted_password).not_to eq(old_encrypted)
        expect(::BCrypt::Password.new(user.encrypted_password)).to eq('new_password')
      end
    end
  end

  describe 'scopes' do
    let!(:active_user) { create(:admin_user, active: true) }
    let!(:inactive_user) { create(:admin_user, :inactive) }

    describe '.active' do
      it 'returns only active users' do
        expect(described_class.active).to include(active_user)
        expect(described_class.active).not_to include(inactive_user)
      end
    end

    describe '.inactive' do
      it 'returns only inactive users' do
        expect(described_class.inactive).to include(inactive_user)
        expect(described_class.inactive).not_to include(active_user)
      end
    end

    describe '.ordered_by_creation' do
      it 'orders by created_at ascending' do
        results = described_class.where(id: [active_user.id, inactive_user.id]).ordered_by_creation
        expect(results.first).to eq(active_user)
      end
    end

    describe '.ordered_by_email' do
      it 'orders by email ascending' do
        user_a = create(:admin_user, email: 'aaa@example.com')
        user_z = create(:admin_user, email: 'zzz@example.com')
        results = described_class.where(id: [user_z.id, user_a.id]).ordered_by_email
        expect(results.first).to eq(user_a)
      end
    end
  end

  describe 'display methods' do
    describe '#full_name' do
      it 'returns first and last name combined' do
        user = build(:admin_user, first_name: 'Max', last_name: 'Mustermann')
        expect(user.full_name).to eq('Max Mustermann')
      end

      it 'returns only first_name when last_name is blank' do
        user = build(:admin_user, first_name: 'Max', last_name: nil)
        expect(user.full_name).to eq('Max')
      end

      it 'returns only last_name when first_name is blank' do
        user = build(:admin_user, first_name: nil, last_name: 'Mustermann')
        expect(user.full_name).to eq('Mustermann')
      end

      it 'falls back to email prefix when both names are blank' do
        user = build(:admin_user, first_name: '', last_name: '', email: 'fallback@example.com')
        expect(user.full_name).to eq('fallback')
      end

      it 'falls back to email prefix when both names are nil' do
        user = build(:admin_user, first_name: nil, last_name: nil, email: 'test@example.com')
        expect(user.full_name).to eq('test')
      end
    end

    describe '#display_name (served by User::NameDisplay since S3)' do
      # The former class-level shadow was bit-identical to the concern; these
      # examples now pin that the CONCERN keeps the admin contract.
      it 'returns full_name when names are present' do
        user = build(:admin_user, first_name: 'Max', last_name: 'Mustermann')
        expect(user.display_name).to eq('Max Mustermann')
      end

      it 'returns email prefix when names are blank' do
        user = build(:admin_user, first_name: '', last_name: '', email: 'test@example.com')
        expect(user.display_name).to eq('test')
      end

      # The admin backend keeps the login address, whatever a member shows to
      # others (User::EmailDisplay); the admin full_name shadow decides it.
      it 'keeps the login address prefix for a nameless member who hides it' do
        user = build(:admin_user, first_name: '', last_name: '', email: 'test@example.com', email_visibility: 'none')
        expect(user.display_name).to eq('test')
      end
    end

    describe 'which email the others see (twin of ::User)' do
      it 'answers shown_email like ::User and refuses the same values' do
        user = build(:admin_user, email: 'login@example.com', email_visibility: 'contact', contact_email: 'team@example.com')
        expect(user.shown_email).to eq('team@example.com')

        user.email_visibility = 'public'
        expect(user).not_to be_valid
        expect(user.errors.details[:email_visibility]).to include(a_hash_including(error: :inclusion))
      end
    end

    describe '#status_text' do
      it 'returns Aktiv for active users' do
        user = build(:admin_user, active: true)
        expect(user.status_text).to eq('Aktiv')
      end

      it 'returns Inaktiv for inactive users' do
        user = build(:admin_user, active: false)
        expect(user.status_text).to eq('Inaktiv')
      end
    end

    describe '#initials (replaced the single-letter avatar_initials in S3)' do
      # The admin user list circle now shows the same two letters as the app
      # (User::NameDisplay); the divergent one-letter implementation is gone.
      it 'returns two letters for a full name' do
        user = build(:admin_user, first_name: 'max', last_name: 'mustermann')
        expect(user.initials).to eq('MM')
      end

      it 'falls back to the email local part when names are blank' do
        user = build(:admin_user, first_name: '', last_name: '', email: 'test@example.com')
        expect(user.initials).to eq('TE')
      end

      it 'handles unicode first names' do
        user = build(:admin_user, first_name: 'Über', last_name: 'Zeug')
        expect(user.initials).to eq('ÜZ')
      end
    end
  end

  describe 'statistics methods' do
    let(:user) { create(:admin_user) }
    let(:org1) { create(:organisation) }
    let(:org2) { create(:organisation) }

    describe '#total_organisations_count' do
      it 'returns 0 when user has no memberships' do
        expect(user.total_organisations_count).to eq(0)
      end

      it 'counts distinct organisations' do
        create_admin_membership(user: user, organisation: org1)
        create_admin_membership(user: user, organisation: org2)
        expect(user.total_organisations_count).to eq(2)
      end
    end

    describe '#active_memberships_count' do
      it 'returns 0 when user has no memberships' do
        expect(user.active_memberships_count).to eq(0)
      end

      it 'counts only active memberships' do
        create_admin_membership(user: user, organisation: org1, active: true)
        create_admin_membership(user: user, organisation: org2, active: false)
        expect(user.active_memberships_count).to eq(1)
      end
    end

    describe '#total_projects_with_access_count' do
      it 'returns 0 when user has no project permissions' do
        expect(user.total_projects_with_access_count).to eq(0)
      end

      it 'counts project permissions' do
        ActsAsTenant.with_tenant(org1) do
          project = create(:project, organisation: org1)
          create(:project_permission, user_id: user.id, project: project)
        end
        expect(user.total_projects_with_access_count).to eq(1)
      end
    end

    describe '#account_admin_organisations_count' do
      it 'returns 0 when user has no admin roles' do
        create_admin_membership(user: user, organisation: org1)
        expect(user.account_admin_organisations_count).to eq(0)
      end

      it 'counts memberships with account_admin role' do
        admin_role = ActsAsTenant.with_tenant(org1) { create(:admin_role, organisation: org1) }
        create_admin_membership(user: user, organisation: org1, role: admin_role)
        expect(user.account_admin_organisations_count).to eq(1)
      end

      it 'does not count non-admin roles' do
        regular_role = ActsAsTenant.with_tenant(org1) { create(:role, organisation: org1, title: 'member') }
        admin_role = ActsAsTenant.with_tenant(org2) { create(:admin_role, organisation: org2) }
        create_admin_membership(user: user, organisation: org1, role: regular_role)
        create_admin_membership(user: user, organisation: org2, role: admin_role)
        expect(user.account_admin_organisations_count).to eq(1)
      end
    end
  end

  describe 'membership helper methods' do
    let(:user) { create(:admin_user) }
    let(:org) { create(:organisation) }

    describe '#membership_in_organisation' do
      it 'returns the membership for given organisation' do
        membership = create_admin_membership(user: user, organisation: org)
        expect(user.membership_in_organisation(org.id)).to eq(membership)
      end

      it 'returns nil when no membership exists' do
        expect(user.membership_in_organisation(org.id)).to be_nil
      end

      it 'returns nil for non-existent organisation_id' do
        expect(user.membership_in_organisation(SecureRandom.uuid)).to be_nil
      end
    end

    describe '#active_membership_in_organisation?' do
      it 'returns true when membership is active' do
        create_admin_membership(user: user, organisation: org, active: true)
        expect(user.active_membership_in_organisation?(org.id)).to be(true)
      end

      it 'returns false when membership is inactive' do
        create_admin_membership(user: user, organisation: org, active: false)
        expect(user.active_membership_in_organisation?(org.id)).to be(false)
      end

      it 'returns nil when no membership exists' do
        expect(user.active_membership_in_organisation?(org.id)).to be_nil
      end
    end

    describe '#role_in_organisation' do
      it 'returns the role for given organisation' do
        role = ActsAsTenant.with_tenant(org) { create(:role, organisation: org) }
        create_admin_membership(user: user, organisation: org, role: role)
        expect(user.role_in_organisation(org.id).id).to eq(role.id)
      end

      it 'returns nil when membership has no role' do
        Admin::Membership.create!(
          user_id: user.id, organisation_id: org.id,
          role_id: nil, active: true
        )
        expect(user.role_in_organisation(org.id)).to be_nil
      end

      it 'returns nil when no membership exists' do
        expect(user.role_in_organisation(org.id)).to be_nil
      end
    end
  end

  describe 'deletion methods' do
    describe '#deleted?' do
      it 'returns true when deleted_at is set' do
        user = build(:admin_user, :soft_deleted)
        expect(user).to be_deleted
      end

      it 'returns false when deleted_at is nil' do
        user = build(:admin_user)
        expect(user).not_to be_deleted
      end
    end

    describe '#deletion_scheduled?' do
      it 'returns true when scheduled_deletion_at is in the future' do
        user = build(:admin_user, :with_scheduled_deletion)
        expect(user).to be_deletion_scheduled
      end

      it 'returns false when scheduled_deletion_at is in the past' do
        user = build(:admin_user, scheduled_deletion_at: 1.day.ago)
        expect(user).not_to be_deletion_scheduled
      end

      it 'returns false when scheduled_deletion_at is nil' do
        user = build(:admin_user, scheduled_deletion_at: nil)
        expect(user).not_to be_deletion_scheduled
      end

      it 'returns false when scheduled_deletion_at is exactly now' do
        travel_to Time.zone.local(2026, 3, 1, 12, 0, 0) do
          user = build(:admin_user, scheduled_deletion_at: Time.current)
          expect(user).not_to be_deletion_scheduled
        end
      end
    end

    describe '#days_until_deletion' do
      it 'returns nil when deletion is not scheduled' do
        user = build(:admin_user, scheduled_deletion_at: nil)
        expect(user.days_until_deletion).to be_nil
      end

      it 'returns nil when scheduled_deletion_at is in the past' do
        user = build(:admin_user, scheduled_deletion_at: 1.day.ago)
        expect(user.days_until_deletion).to be_nil
      end

      it 'returns correct number of days when scheduled in the future' do
        travel_to Time.zone.local(2026, 3, 1, 12, 0, 0) do
          user = build(:admin_user, scheduled_deletion_at: 30.days.from_now)
          expect(user.days_until_deletion).to eq(30)
        end
      end

      it 'rounds up partial days' do
        travel_to Time.zone.local(2026, 3, 1, 12, 0, 0) do
          user = build(:admin_user, scheduled_deletion_at: 1.5.days.from_now)
          expect(user.days_until_deletion).to eq(2)
        end
      end

      it 'returns 1 for less than a day remaining' do
        travel_to Time.zone.local(2026, 3, 1, 12, 0, 0) do
          user = build(:admin_user, scheduled_deletion_at: 2.hours.from_now)
          expect(user.days_until_deletion).to eq(1)
        end
      end
    end

    describe '#should_be_recommended_for_deletion?' do
      let(:user) { create(:admin_user) }
      let(:org) { create(:organisation) }

      it 'returns true when user has no active memberships' do
        expect(user).to be_should_be_recommended_for_deletion
      end

      it 'returns true when user has only inactive memberships' do
        create_admin_membership(user: user, organisation: org, active: false)
        expect(user).to be_should_be_recommended_for_deletion
      end

      it 'returns false when user has active memberships' do
        create_admin_membership(user: user, organisation: org, active: true)
        expect(user).not_to be_should_be_recommended_for_deletion
      end

      it 'returns false when user is already deleted' do
        user.update_columns(deleted_at: 1.day.ago)
        expect(user).not_to be_should_be_recommended_for_deletion
      end
    end

    describe '#mark_for_deletion_review!' do
      it 'sets deletion_recommended to true' do
        user = create(:admin_user)
        user.mark_for_deletion_review!
        expect(user.reload.deletion_recommended).to be(true)
      end

      it 'does not update if user is already deleted' do
        user = create(:admin_user, :soft_deleted)
        user.mark_for_deletion_review!
        expect(user.reload.deletion_recommended).to be(false)
      end

      it 'is idempotent for non-deleted users' do
        user = create(:admin_user, :recommended_for_deletion)
        expect { user.mark_for_deletion_review! }.not_to raise_error
      end
    end

    describe '#can_be_deleted_by?' do
      let(:user) { create(:admin_user) }

      it 'returns true for a Beuser requester' do
        beuser = create(:beuser)
        expect(user.can_be_deleted_by?(beuser)).to be(true)
      end

      it 'returns true for a Beuser with backend source' do
        beuser = create(:beuser)
        expect(user.can_be_deleted_by?(beuser, 'backend')).to be(true)
      end

      it 'returns false when user is already deleted' do
        user.update_columns(deleted_at: 1.day.ago)
        beuser = create(:beuser)
        expect(user.can_be_deleted_by?(beuser)).to be(false)
      end

      it 'returns false when requester is not a Beuser' do
        other_user = create(:admin_user)
        expect(user.can_be_deleted_by?(other_user)).to be(false)
      end

      it 'returns false for non-backend source' do
        beuser = create(:beuser)
        expect(user.can_be_deleted_by?(beuser, 'frontend')).to be(false)
      end

      it 'returns false for empty string source' do
        beuser = create(:beuser)
        expect(user.can_be_deleted_by?(beuser, '')).to be(false)
      end

      it 'returns true when source is nil (no source check)' do
        beuser = create(:beuser)
        expect(user.can_be_deleted_by?(beuser, nil)).to be(true)
      end
    end
  end

  describe 'anonymization methods' do
    describe '#anonymize!' do
      let(:user) do
        create(:admin_user,
               first_name: 'Max',
               last_name: 'Mustermann',
               email: 'max@example.com',
               password: 'secret123')
      end

      it 'sets first_name and last_name to Anonym' do
        user.anonymize!
        user.reload
        expect(user.first_name).to eq('Anonym')
        expect(user.last_name).to eq('Anonym')
      end

      it 'generates anonymized email with UUID' do
        user.anonymize!
        user.reload
        expect(user.email).to match(/\Adeleted_user_[0-9a-f-]{36}@deleted\.local\z/)
      end

      it 'clears encrypted_password' do
        user.anonymize!
        user.reload
        expect(user.encrypted_password).to eq('')
      end

      it 'clears reset_password_token and reset_password_sent_at' do
        user.update_columns(reset_password_token: 'token123', reset_password_sent_at: 1.hour.ago)
        user.anonymize!
        user.reload
        expect(user.reset_password_token).to be_nil
        expect(user.reset_password_sent_at).to be_nil
      end

      it 'clears remember_created_at' do
        user.update_columns(remember_created_at: 1.day.ago)
        user.anonymize!
        user.reload
        expect(user.remember_created_at).to be_nil
      end

      it 'generates unique emails for concurrent anonymizations' do
        user2 = create(:admin_user, email: 'other@example.com', password: 'secret123')
        Prosopite.pause do
          user.anonymize!
          user2.anonymize!
          expect(user.reload.email).not_to eq(user2.reload.email)
        end
      end

      it 'bypasses validations via update_columns' do
        user.anonymize!
        expect(user.reload.first_name).to eq('Anonym')
      end
    end

    describe '#soft_delete_and_anonymize!' do
      let(:user) { create(:admin_user, password: 'secret123') }
      let(:org) { create(:organisation) }

      it 'removes all memberships' do
        create_admin_membership(user: user, organisation: org)
        expect { user.soft_delete_and_anonymize! }
          .to change { Admin::Membership.where(user_id: user.id).count }.from(1).to(0)
      end

      it 'sets deleted_at' do
        travel_to Time.zone.local(2026, 3, 1, 12, 0, 0) do
          user.soft_delete_and_anonymize!
          expect(user.reload.deleted_at).to be_within(1.second).of(Time.current)
        end
      end

      it 'sets deletion_recommended to true' do
        user.soft_delete_and_anonymize!
        expect(user.reload.deletion_recommended).to be(true)
      end

      it 'anonymizes user data' do
        user.soft_delete_and_anonymize!
        user.reload
        expect(user.first_name).to eq('Anonym')
        expect(user.last_name).to eq('Anonym')
        expect(user.email).to match(/\Adeleted_user_[0-9a-f-]{36}@deleted\.local\z/)
        expect(user.encrypted_password).to eq('')
      end

      it 'runs in a transaction (rolls back on error)' do
        create_admin_membership(user: user, organisation: org)
        allow(user).to receive(:update_columns).and_raise(ActiveRecord::ActiveRecordError)
        expect { user.soft_delete_and_anonymize! }.to raise_error(ActiveRecord::ActiveRecordError)
        expect(Admin::Membership.where(user_id: user.id).count).to eq(1)
      end

      it 'handles user with no memberships' do
        expect { user.soft_delete_and_anonymize! }.not_to raise_error
        expect(user.reload).to be_deleted
      end

      it 'handles user with multiple memberships across organisations' do
        org2 = create(:organisation)
        create_admin_membership(user: user, organisation: org)
        create_admin_membership(user: user, organisation: org2)
        user.soft_delete_and_anonymize!
        expect(Admin::Membership.where(user_id: user.id).count).to eq(0)
        expect(user.reload).to be_deleted
      end
    end
  end

  describe 'eager loading methods' do
    let(:user) { create(:admin_user) }

    describe '#memberships_with_details' do
      it 'returns memberships with included associations' do
        org = create(:organisation)
        role = ActsAsTenant.with_tenant(org) { create(:role, organisation: org) }
        Admin::Membership.create!(
          user_id: user.id, organisation_id: org.id,
          role_id: role.id, active: true
        )

        result = user.memberships_with_details
        expect(result).to be_present
        membership = result.first
        expect(membership.association(:organisation)).to be_loaded
        expect(membership.association(:role)).to be_loaded
      end
    end

    describe '#project_permissions_with_details' do
      it 'returns project_permissions with included project' do
        org = create(:organisation)
        ActsAsTenant.with_tenant(org) do
          project = create(:project, organisation: org)
          create(:project_permission, user_id: user.id, project: project)
        end

        result = user.project_permissions_with_details
        expect(result).to be_present
        expect(result.first.association(:project)).to be_loaded
      end

      it 'orders by project name' do
        org = create(:organisation)
        ActsAsTenant.with_tenant(org) do
          project_b = create(:project, organisation: org, name: 'Bravo')
          project_a = create(:project, organisation: org, name: 'Alpha')
          create(:project_permission, user_id: user.id, project: project_b)
          create(:project_permission, user_id: user.id, project: project_a)
        end

        result = user.project_permissions_with_details
        expect(result.map { |pp| pp.project.name }).to eq(%w[Alpha Bravo])
      end
    end
  end
end
