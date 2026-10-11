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

RSpec.describe User, type: :model do
  # NOTE: The authentication surface — Devise module registration, the custom
  # email/password validations, the session_timeout_minutes inclusion validation
  # and #timeout_in — was extracted into User::Authenticatable (user.rb split,
  # slice 6/7). Its characterization specs (incl. the soft-delete-aware email
  # uniqueness, password_required? gating, the User::ALLOWED_SESSION_TIMEOUTS
  # contract and a no-stub Devise lifecycle pass) live in
  # spec/models/user/authenticatable_spec.rb.

  # language_preference is i18n / profile, NOT authentication, so it deliberately
  # stays on User (it did not move into User::Authenticatable). It was untested
  # before slice 6 touched this area; pinned here so the inclusion validation and
  # the DB default cannot drift silently.
  describe 'language_preference' do
    %w[de en].each do |lang|
      it "accepts #{lang.inspect}" do
        expect(build(:user, language_preference: lang)).to be_valid
      end
    end

    ['fr', 'EN', 'de ', '', 'xx'].each do |bad|
      it "rejects #{bad.inspect}" do
        user = build(:user, language_preference: bad)
        expect(user).not_to be_valid
        expect(user.errors[:language_preference]).to be_present
      end
    end

    it 'defaults to "de" on insert when omitted (DB default, not the factory)' do
      # The factory does not set language_preference, so this exercises the
      # column default default("de"), not a factory value.
      user = User.create!(
        email: "lang-default-#{SecureRandom.hex(4)}@example.com",
        password: 'password123', first_name: 'L', last_name: 'P'
      )
      expect(user.reload.language_preference).to eq('de')
    end
  end

  describe 'associations' do
    it { should have_many(:memberships).dependent(:destroy) }
    it { should have_many(:organisations).through(:memberships) }
    it { should have_many(:roles).through(:memberships) }
    it { should have_many(:posts).dependent(:destroy) }
    it { should have_many(:project_permissions).dependent(:destroy) }
    it { should have_many(:permitted_projects).through(:project_permissions) }
    it { should have_many(:ticket_assignments).dependent(:destroy) }
    it { should have_many(:assigned_tickets).through(:ticket_assignments) }

    # dependent: contract for the remaining owned associations — these had NO
    # guard, so removing/changing a `dependent:` option went unnoticed. The
    # destroy vs. nullify split is deliberate and load-bearing:
    #   - destroy: data that belongs solely to the user (tokens, permissions,
    #     received notifications, notification settings) is cleaned up;
    #   - nullify: records that OUTLIVE the user (people they invited, index runs
    #     they triggered, notifications they authored) keep existing with the
    #     back-reference nulled — flipping any of these to :destroy would delete
    #     real, still-needed rows.
    it { should have_many(:time_session_permissions).dependent(:destroy) }
    it { should have_many(:notifications).dependent(:destroy) }
    it { should have_many(:notification_preferences).dependent(:destroy) }
    it { should have_many(:notification_subscriptions).dependent(:destroy) }
    it { should have_many(:personal_access_tokens).dependent(:destroy) }
    it { should have_many(:invited_users).dependent(:nullify) }
    it { should have_many(:triggered_index_runs).dependent(:nullify) }
    it { should have_many(:created_notifications).dependent(:nullify) }
  end

  describe 'database columns' do
    it { should have_db_column(:active).of_type(:boolean).with_options(default: true, null: false) }
  end

  describe 'scopes' do
    let!(:active_user1) { create(:user, active: true) }
    let!(:active_user2) { create(:user, active: true) }
    let!(:inactive_user1) { create(:user, active: false) }
    let!(:inactive_user2) { create(:user, active: false) }

    describe '.active' do
      it 'returns only active users' do
        expect(User.active).to contain_exactly(active_user1, active_user2)
      end

      it 'excludes inactive users' do
        expect(User.active).not_to include(inactive_user1, inactive_user2)
      end
    end

    describe '.inactive' do
      it 'returns only inactive users' do
        expect(User.inactive).to contain_exactly(inactive_user1, inactive_user2)
      end

      it 'excludes active users' do
        expect(User.inactive).not_to include(active_user1, active_user2)
      end
    end
  end

  describe 'default values' do
    it 'sets active to true by default for new users' do
      user = User.new
      expect(user.active).to be true
    end

    it 'can be explicitly set to false' do
      user = User.new(active: false)
      expect(user.active).to be false
    end
  end

  describe '#active?' do
    it 'returns true for active users' do
      user = build(:user, active: true)
      expect(user.active?).to be true
    end

    it 'returns false for inactive users' do
      user = build(:user, active: false)
      expect(user.active?).to be false
    end

    it 'creates a user with expected attributes' do
      user = create(:user, first_name: 'John', last_name: 'Doe')
      expect(user.email).to include('@example.com')
      expect(user.first_name).to eq('John')
      expect(user.last_name).to eq('Doe')
      expect(user.is_ai).to be false
    end

    it 'creates a user with organisation when using with_organisation trait' do
      user = create(:user, :with_organisation)
      expect(user.organisations.count).to eq(1)
      expect(user.memberships.first.active).to be true
    end

    it 'ensures email uniqueness' do
      create(:user, email: 'duplicate@example.com')
      expect do
        create(:user, email: 'duplicate@example.com')
      end.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  # NOTE: The organisation-membership query helpers (#member_of_organisation?,
  # #active_member_of_organisation?, #active_memberships, #active_organisations,
  # #role_in_organisation, incl. the two request-level caches @role_cache /
  # @active_member_cache) were extracted into User::OrganisationMembership
  # (user.rb split, slice 7/7). Their characterization specs now live in
  # spec/models/user/organisation_membership_spec.rb. #full_name / #display_name
  # are identity, not membership, so they deliberately STAY on User and here.

  describe '#full_name' do
    it 'returns the first and last name combined' do
      user = build(:user, first_name: 'John', last_name: 'Doe')
      expect(user.full_name).to eq('John Doe')
    end

    it 'handles nil values' do
      user = build(:user, first_name: nil, last_name: nil)
      expect(user.full_name).to eq(' ')
    end
  end

  # display_name = full_name.presence&.strip || email.split('@').first.
  # It was used as a value in other specs but its OWN chain (presence / strip /
  # email fallback) was never pinned — each clause below targets one link.
  describe '#display_name' do
    it 'returns the full name when both parts are present' do
      expect(build(:user, first_name: 'John', last_name: 'Doe').display_name).to eq('John Doe')
    end

    # full_name with one half nil is " Doe" / "John " — present but padded.
    # Pins the `.strip`: a mutant dropping it would leak the leading/trailing space.
    it 'strips the padding from a half-empty name' do
      expect(build(:user, first_name: nil, last_name: 'Doe').display_name).to eq('Doe')
      expect(build(:user, first_name: 'John', last_name: nil).display_name).to eq('John')
    end

    # Both names blank -> full_name is " " -> presence is nil -> fall back to the
    # email local-part. Pins the `.presence` and the `email.split('@').first`:
    # dropping `.presence` would return " " (whitespace) instead of the email,
    # and `.first` -> `.last` would return the domain.
    it 'falls back to the email local-part when the name is blank' do
      user = build(:user, first_name: nil, last_name: nil, email: 'alice@example.com')
      expect(user.display_name).to eq('alice')
    end
  end

  # NOTE: The authorization surface (#account_admin_in?,
  # #has_permission_in_organisation?, #can_access_project?,
  # #accessible_projects, #time_session_permission_for, #can_view_ticket?,
  # #can_view_project?) was extracted into User::Authorization (user.rb split,
  # slice 7/7). Its characterization specs — positive AND negative, plus the
  # AccessCheck::ProjectAccessService delegation / default-argument pins — now
  # live in spec/models/user/authorization_spec.rb.

  describe 'when destroying a user' do
    let(:user) { create(:user) }
    let(:organisation) { create(:organisation) }
    let(:project) do
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation)
      end
    end

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation)
        create(:project_permission, user: user, project: project)

        # Setup ticket and post
        ticket = create(:ticket, project: project, organisation: organisation)
        create(:post, user: user, ticket: ticket, organisation: organisation)
        create(:ticket_assignment, user: user, ticket: ticket)
      end
    end

    it 'destroys all associated records' do
      ActsAsTenant.with_tenant(organisation) do
        expect { user.destroy }.to change(Membership, :count).by(-1)
                                                             .and change(ProjectPermission, :count).by(-1)
                                                                                                   .and change(Post, :count).by(-1)
                                                                                                                            .and change(TicketAssignment, :count).by(-1)
      end
    end
  end

  describe 'soft deletable functionality' do
    it 'includes SoftDeletable concern' do
      expect(described_class.ancestors).to include(SoftDeletable)
    end

    it 'responds to soft delete methods' do
      user = create(:user)
      expect(user).to respond_to(:soft_delete!)
      expect(user).to respond_to(:restore!)
      expect(user).to respond_to(:deleted?)
    end
  end

  describe 'invite tracking associations' do
    let(:inviter) { create(:user) }
    let(:invited_user) { create(:user, invited_by_user: inviter, invited_by_org: organisation) }
    let(:organisation) { create(:organisation) }

    it 'belongs to invited_by_user' do
      expect(invited_user.invited_by_user).to eq(inviter)
    end

    it 'belongs to invited_by_org' do
      expect(invited_user.invited_by_org).to eq(organisation)
    end

    it 'allows nil values for invite tracking' do
      user = create(:user, invited_by_user: nil, invited_by_org: nil)
      expect(user).to be_valid
    end

    # Data-safety contract behind invited_users dependent: :nullify (asserted as
    # a reflection above; here proven end-to-end): deleting an INVITER must NOT
    # delete the people they invited — only null the back-reference. A mutant
    # flipping :nullify -> :destroy would wipe real users. destroy is wrapped in a
    # tenant because the User cascade touches tenanted associations.
    it 'nullifies the invite link (does not destroy the invitee) when the inviter is deleted' do
      inviter = create(:user)
      invitee = create(:user, invited_by_user: inviter)
      ActsAsTenant.with_tenant(organisation) { inviter.destroy }
      expect(User.exists?(invitee.id)).to be true
      expect(invitee.reload.invited_by_user_id).to be_nil
    end
  end

  # NOTE: The account-deletion / GDPR lifecycle methods (#anonymize!,
  # #soft_delete_and_anonymize!, #schedule_deletion!, #cancel_scheduled_deletion!,
  # #deletion_scheduled?, #days_until_deletion, #can_be_deleted_by?,
  # #mark_for_deletion_review!, #should_be_recommended_for_deletion?) were
  # extracted into User::DeletionLifecycle (user.rb split, slice 5/7). Their
  # characterization specs now live in spec/models/user/deletion_lifecycle_spec.rb.

  describe 'deletion_recommended scope' do
    let!(:recommended_user) { create(:user, deletion_recommended: true) }
    let!(:normal_user) { create(:user, deletion_recommended: false) }

    it 'finds users recommended for deletion' do
      expect(described_class.where(deletion_recommended: true)).to contain_exactly(recommended_user)
    end
  end

  # NOTE: 'email uniqueness with soft delete' moved to
  # spec/models/user/authenticatable_spec.rb together with the rest of the
  # authentication surface (user.rb split, slice 6/7).

  describe '#unread_notifications_count' do
    let(:organisation) { create(:organisation) }
    let(:user) { create(:user) }

    before { ActsAsTenant.current_tenant = organisation }
    after  { ActsAsTenant.current_tenant = nil }

    # Regression: the banner showed an org-wide count including notifications for
    # projects the user no longer has access to. Expected: only notifications
    # from accessible projects + project-less system notifications.
    context 'when user is not an account admin and has no project access' do
      let(:inaccessible_project) { create(:project, organisation: organisation) }

      before do
        regular_role = create(:role, organisation: organisation, title: 'regular_user')
        create(:membership, user: user, organisation: organisation, role: regular_role)
      end

      it 'excludes unread notifications belonging to inaccessible projects' do
        create(:notification, :unread, recipient: user, organisation: organisation,
                                       project: inaccessible_project, channel: 'in_app')
        create(:notification, :unread, recipient: user, organisation: organisation,
                                       project: nil, channel: 'in_app',
                                       notifiable: organisation)

        expect(user.unread_notifications_count(organisation)).to eq(1)
      end
    end

    context 'when user is an account admin' do
      let(:project) { create(:project, organisation: organisation) }

      before do
        admin_role = create(:role, organisation: organisation, title: 'account_admin')
        create(:membership, user: user, organisation: organisation, role: admin_role)
      end

      it 'counts all unread notifications in the organisation' do
        create(:notification, :unread, recipient: user, organisation: organisation,
                                       project: project, channel: 'in_app')
        create(:notification, :unread, recipient: user, organisation: organisation,
                                       project: nil, channel: 'in_app',
                                       notifiable: organisation)

        expect(user.unread_notifications_count(organisation)).to eq(2)
      end

      it 'ignores read and archived notifications' do
        create(:notification, recipient: user, organisation: organisation,
                              project: project, channel: 'in_app', state: 'read', read_at: 1.minute.ago)
        create(:notification, recipient: user, organisation: organisation,
                              project: project, channel: 'in_app', state: 'archived')

        expect(user.unread_notifications_count(organisation)).to eq(0)
      end

      it 'ignores email-channel notifications' do
        create(:notification, :unread, recipient: user, organisation: organisation,
                                       project: project, channel: 'email')

        expect(user.unread_notifications_count(organisation)).to eq(0)
      end
    end
  end
end
