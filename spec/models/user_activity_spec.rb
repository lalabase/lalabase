# frozen_string_literal: true

# == Schema Information
#
# Table name: user_activities
#
#  id                :uuid             not null, primary key
#  action            :string           not null
#  attribute_changes :jsonb
#  category          :string           not null
#  failure_reason    :text
#  ip_address        :string
#  metadata          :jsonb
#  status            :string           default("success")
#  trackable_type    :string
#  user_agent        :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  organisation_id   :uuid
#  session_id        :string
#  trackable_id      :uuid
#  user_id           :uuid             not null
#
# Indexes
#
#  idx_user_activities_on_category_and_time  (category,created_at)
#  idx_user_activities_on_created_at         (created_at)
#  idx_user_activities_on_ip_and_time        (ip_address,created_at)
#  idx_user_activities_on_org_and_time       (organisation_id,created_at)
#  idx_user_activities_on_session            (session_id)
#  idx_user_activities_on_trackable          (trackable_type,trackable_id)
#  idx_user_activities_on_user_action_time   (user_id,action,created_at)
#  idx_user_activities_on_user_and_time      (user_id,created_at)
#  index_user_activities_on_organisation_id  (organisation_id)
#  index_user_activities_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id)
#
require 'rails_helper'

RSpec.describe UserActivity, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }

  describe 'associations' do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:organisation).optional }
    it { is_expected.to belong_to(:trackable).optional }
  end

  describe 'validations' do
    subject { build(:user_activity, user: user, organisation: organisation) }

    it { is_expected.to validate_presence_of(:action) }
    it { is_expected.to validate_inclusion_of(:action).in_array(described_class::ACTIONS.values) }
    it { is_expected.to validate_inclusion_of(:category).in_array(described_class::CATEGORIES.values) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES.values) }

    # validate_presence_of(:category) can't be tested with shoulda-matchers
    # because the set_defaults callback auto-derives category from action
    it 'requires category (when action is also absent)' do
      activity = described_class.new(user: user, organisation: organisation,
                                     action: nil, category: nil)
      activity.valid?
      expect(activity.errors[:category]).to be_present
    end

    it 'is invalid with an unknown action' do
      activity = build(:user_activity, user: user, organisation: organisation, action: 'unknown_action')
      expect(activity).not_to be_valid
      expect(activity.errors[:action]).to be_present
    end

    it 'is invalid with an unknown category' do
      activity = build(:user_activity, user: user, organisation: organisation, category: 'unknown_category')
      expect(activity).not_to be_valid
      expect(activity.errors[:category]).to be_present
    end

    it 'is invalid with an unknown status' do
      activity = build(:user_activity, user: user, organisation: organisation, status: 'unknown_status')
      expect(activity).not_to be_valid
      expect(activity.errors[:status]).to be_present
    end

    it 'is invalid without a user' do
      activity = build(:user_activity, user: nil, organisation: organisation)
      expect(activity).not_to be_valid
      expect(activity.errors[:user]).to be_present
    end

    it 'is valid without an organisation' do
      activity = build(:user_activity, user: user, organisation: nil)
      expect(activity).to be_valid
    end
  end

  describe 'callbacks' do
    describe '#set_defaults' do
      it 'sets status to success when not provided' do
        activity = build(:user_activity, user: user, organisation: organisation, status: nil)
        activity.valid?
        expect(activity.status).to eq('success')
      end

      it 'does not override an explicitly set status' do
        activity = build(:user_activity, user: user, organisation: organisation, status: 'failed')
        activity.valid?
        expect(activity.status).to eq('failed')
      end

      it 'initializes metadata to empty hash when nil' do
        activity = build(:user_activity, user: user, organisation: organisation, metadata: nil)
        activity.valid?
        expect(activity.metadata).to eq({})
      end

      it 'does not override existing metadata' do
        activity = build(:user_activity, user: user, organisation: organisation, metadata: { 'key' => 'value' })
        activity.valid?
        expect(activity.metadata).to eq({ 'key' => 'value' })
      end

      it 'initializes attribute_changes to empty hash when nil' do
        activity = build(:user_activity, user: user, organisation: organisation, attribute_changes: nil)
        activity.valid?
        expect(activity.attribute_changes).to eq({})
      end

      it 'auto-derives category from action when category is nil' do
        activity = build(:user_activity, user: user, organisation: organisation,
                                         action: 'login', category: nil)
        activity.valid?
        expect(activity.category).to eq('auth')
      end

      it 'does not auto-derive category when action is nil' do
        activity = build(:user_activity, user: user, organisation: organisation,
                                         action: nil, category: nil)
        activity.valid?
        expect(activity.category).to be_nil
      end
    end

    describe '#notify_admins_if_security_event' do
      it 'logs a warning for failed critical events' do
        expect(Rails.logger).to receive(:warn).with(/\[SECURITY\] Critical activity detected/)
        create(:user_activity, :account_locked, user: user, organisation: organisation)
      end

      it 'does not log for successful critical events' do
        expect(Rails.logger).not_to receive(:warn)
        create(:user_activity, :role_assigned, user: user, organisation: organisation)
      end

      it 'does not log for non-critical failed events' do
        expect(Rails.logger).not_to receive(:warn)
        create(:user_activity, :login_failed, user: user, organisation: organisation)
      end
    end
  end

  describe 'scopes' do
    let!(:login_activity) do
      create(:user_activity, :login, user: user, organisation: organisation)
    end
    let!(:failed_login) do
      create(:user_activity, :login_failed, user: user, organisation: organisation)
    end
    let!(:profile_activity) do
      create(:user_activity, :profile_updated, user: user, organisation: organisation)
    end

    describe '.recent' do
      it 'orders by created_at desc' do
        expect(described_class.recent.first).to eq(profile_activity)
      end
    end

    describe '.for_user' do
      let(:other_user) { create(:user, organisation: organisation) }
      let!(:other_activity) do
        create(:user_activity, :login, user: other_user, organisation: organisation)
      end

      it 'returns only activities for the given user' do
        result_ids = described_class.for_user(user).pluck(:id)
        expect(result_ids).to include(login_activity.id, failed_login.id, profile_activity.id)
        expect(result_ids).not_to include(other_activity.id)
      end
    end

    describe '.for_organisation' do
      let(:other_org) { create(:organisation) }
      let(:other_user) { create(:user, organisation: other_org) }
      let!(:other_org_activity) do
        create(:user_activity, :login, user: other_user, organisation: other_org)
      end

      it 'returns only activities for the given organisation' do
        result = described_class.for_organisation(organisation)
        expect(result).to include(login_activity)
        expect(result).not_to include(other_org_activity)
      end
    end

    describe '.for_category' do
      it 'filters by category' do
        result = described_class.for_category('profile')
        expect(result).to include(profile_activity)
        expect(result).not_to include(login_activity)
      end
    end

    describe '.for_action' do
      it 'filters by action' do
        result = described_class.for_action('login')
        expect(result).to include(login_activity)
        expect(result).not_to include(profile_activity)
      end
    end

    describe '.successful' do
      it 'returns only successful activities' do
        result_ids = described_class.successful.pluck(:id)
        expect(result_ids).to include(login_activity.id, profile_activity.id)
        expect(result_ids).not_to include(failed_login.id)
      end
    end

    describe '.failed' do
      it 'returns only failed activities' do
        result = described_class.failed
        expect(result).to include(failed_login)
        expect(result).not_to include(login_activity)
      end
    end

    describe '.today' do
      let!(:old_activity) do
        create(:user_activity, :login, user: user, organisation: organisation,
                                       created_at: 2.days.ago)
      end

      it 'returns only activities from today' do
        result = described_class.today
        expect(result).to include(login_activity)
        expect(result).not_to include(old_activity)
      end
    end

    describe '.this_week' do
      let!(:old_activity) do
        create(:user_activity, :login, user: user, organisation: organisation,
                                       created_at: 2.weeks.ago)
      end

      it 'returns only activities from this week' do
        result = described_class.this_week
        expect(result).to include(login_activity)
        expect(result).not_to include(old_activity)
      end
    end

    describe '.this_month' do
      let!(:old_activity) do
        create(:user_activity, :login, user: user, organisation: organisation,
                                       created_at: 2.months.ago)
      end

      it 'returns only activities from this month' do
        result = described_class.this_month
        expect(result).to include(login_activity)
        expect(result).not_to include(old_activity)
      end
    end

    # Both scopes above bound their range with a DATE (Date#end_of_week / #end_of_month),
    # which Rails binds as midnight, so the whole last day fell outside. The examples
    # above cannot see it: they only ever ask about "now", and "now" is inside the range
    # on every day except the last one. Time is frozen here so the boundary is asserted
    # on every run rather than on the days the calendar happens to allow.
    describe 'range boundaries on the last day of the period' do
      include ActiveSupport::Testing::TimeHelpers

      def activity_at(moment)
        create(:user_activity, :login, user: user, organisation: organisation, created_at: moment)
      end

      context 'on a Sunday' do
        around { |example| travel_to(Time.zone.parse('2026-09-06 22:30:00')) { example.run } }

        it 'keeps the last moment of the week and drops the first of the next' do
          expect(described_class.this_week).to include(activity_at(Time.current.end_of_week))
          expect(described_class.this_week).not_to include(activity_at(Time.current.end_of_week + 1.second))
        end
      end

      context 'on the last day of a month' do
        around { |example| travel_to(Time.zone.parse('2026-09-30 22:30:00')) { example.run } }

        it 'keeps the last moment of the month and drops the first of the next' do
          expect(described_class.this_month).to include(activity_at(Time.current.end_of_month))
          expect(described_class.this_month).not_to include(activity_at(Time.current.end_of_month + 1.second))
        end
      end
    end

    describe '.between' do
      let(:boundary_time) { 10.days.ago.beginning_of_day }
      let!(:old_activity) do
        create(:user_activity, :login, user: user, organisation: organisation,
                                       created_at: boundary_time)
      end

      it 'returns activities within the date range' do
        result_ids = described_class.between(2.days.ago, Time.current).pluck(:id)
        expect(result_ids).to include(login_activity.id)
        expect(result_ids).not_to include(old_activity.id)
      end

      it 'includes activities at boundary dates' do
        result_ids = described_class.between(boundary_time, Time.current).pluck(:id)
        expect(result_ids).to include(login_activity.id, old_activity.id)
      end
    end

    describe 'category convenience scopes' do
      let!(:security_activity) do
        create(:user_activity, :suspicious_activity, user: user, organisation: organisation)
      end
      let!(:invitation_activity) do
        create(:user_activity, :invitation_sent, user: user, organisation: organisation)
      end

      it '.auth_activities returns auth category' do
        expect(described_class.auth_activities).to include(login_activity)
        expect(described_class.auth_activities).not_to include(profile_activity)
      end

      it '.profile_activities returns profile category' do
        expect(described_class.profile_activities).to include(profile_activity)
        expect(described_class.profile_activities).not_to include(login_activity)
      end

      it '.security_activities returns security category' do
        expect(described_class.security_activities).to include(security_activity)
        expect(described_class.security_activities).not_to include(login_activity)
      end

      it '.permission_activities returns permissions category' do
        perm = create(:user_activity, :role_assigned, user: user, organisation: organisation)
        expect(described_class.permission_activities).to include(perm)
        expect(described_class.permission_activities).not_to include(login_activity)
      end
    end

    describe 'scope chaining' do
      it 'chains multiple scopes correctly' do
        result = described_class.for_user(user).successful.auth_activities.recent
        expect(result).to include(login_activity)
        expect(result).not_to include(failed_login)
        expect(result).not_to include(profile_activity)
      end
    end
  end

  describe '.track!' do
    it 'creates an activity with basic attributes' do
      activity = described_class.track!(user, 'login')
      expect(activity).to be_persisted
      expect(activity.action).to eq('login')
      expect(activity.category).to eq('auth')
      expect(activity.status).to eq('success')
      expect(activity.user).to eq(user)
    end

    it 'auto-derives category from action' do
      activity = described_class.track!(user, 'profile_updated')
      expect(activity.category).to eq('profile')
    end

    it 'accepts metadata option' do
      activity = described_class.track!(user, 'login', metadata: { 'browser' => 'Chrome' })
      expect(activity.metadata).to eq({ 'browser' => 'Chrome' })
    end

    it 'accepts attribute changes option' do
      activity = described_class.track!(user, 'email_changed',
                                        changes: { 'email' => %w[old@test.com new@test.com] })
      expect(activity.attribute_changes).to eq({ 'email' => %w[old@test.com new@test.com] })
    end

    it 'accepts trackable option' do
      activity = described_class.track!(user, 'role_assigned', trackable: organisation)
      expect(activity.trackable).to eq(organisation)
    end

    it 'accepts explicit organisation' do
      other_org = create(:organisation)
      activity = described_class.track!(user, 'login', organisation: other_org)
      expect(activity.organisation).to eq(other_org)
    end

    it 'falls back to user.organisations.first when no organisation given' do
      activity = described_class.track!(user, 'login')
      expect(activity.organisation).to eq(user.organisations.first)
    end

    it 'handles user with no organisations gracefully' do
      user_without_org = create(:user)
      activity = described_class.track!(user_without_org, 'login')
      expect(activity.organisation).to be_nil
    end

    it 'accepts failure_reason option' do
      activity = described_class.track!(user, 'login_failed', failure_reason: 'Bad password')
      expect(activity.failure_reason).to eq('Bad password')
    end

    context 'with request object' do
      let(:request) do
        instance_double(ActionDispatch::Request,
                        remote_ip: '10.0.0.1',
                        user_agent: 'TestAgent/1.0',
                        session: instance_double(ActionDispatch::Request::Session, id: 'session-abc'))
      end

      it 'extracts IP address from request' do
        activity = described_class.track!(user, 'login', request: request)
        expect(activity.ip_address).to eq('10.0.0.1')
      end

      it 'extracts user agent from request' do
        activity = described_class.track!(user, 'login', request: request)
        expect(activity.user_agent).to eq('TestAgent/1.0')
      end

      it 'extracts session ID from request' do
        activity = described_class.track!(user, 'login', request: request)
        expect(activity.session_id).to eq('session-abc')
      end

      it 'does not mutate the caller options hash' do
        options = { request: request, metadata: { 'key' => 'val' } }
        options_before = options.dup
        described_class.track!(user, 'login', **options)
        expect(options).to eq(options_before)
      end
    end

    context 'without request object' do
      it 'leaves request fields nil' do
        activity = described_class.track!(user, 'login')
        expect(activity.ip_address).to be_nil
        expect(activity.user_agent).to be_nil
        expect(activity.session_id).to be_nil
      end
    end

    it 'raises on invalid action' do
      expect do
        described_class.track!(user, 'completely_invalid')
      end.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe '.track_failure!' do
    it 'creates a failed activity with reason' do
      activity = described_class.track_failure!(user, 'login_failed', 'Wrong password')
      expect(activity.status).to eq('failed')
      expect(activity.failure_reason).to eq('Wrong password')
    end

    it 'passes additional options through' do
      activity = described_class.track_failure!(user, 'login_failed', 'Wrong password',
                                                metadata: { 'attempts' => 3 })
      expect(activity.metadata).to eq({ 'attempts' => 3 })
    end

    it 'does not allow status override via options' do
      activity = described_class.track_failure!(user, 'login_failed', 'Wrong password',
                                                status: 'success')
      expect(activity.status).to eq('failed')
    end
  end

  describe '.category_for_action' do
    described_class::ACTIONS.each do |key, action_value|
      it "maps #{key} to the correct category" do
        category = described_class.category_for_action(action_value)
        expect(described_class::CATEGORIES.values).to include(category)
      end
    end

    it 'maps login actions to auth' do
      %w[login logout login_failed registered password_reset_requested
         password_reset_completed].each do |action|
        expect(described_class.category_for_action(action)).to eq('auth')
      end
    end

    it 'maps profile actions to profile' do
      %w[email_changed profile_updated].each do |action|
        expect(described_class.category_for_action(action)).to eq('profile')
      end
    end

    it 'maps permission actions to permissions' do
      %w[role_assigned role_removed permissions_changed
         project_access_granted project_access_revoked].each do |action|
        expect(described_class.category_for_action(action)).to eq('permissions')
      end
    end

    it 'maps security actions to security' do
      %w[account_locked account_unlocked api_token_created
         api_token_deleted suspicious_activity].each do |action|
        expect(described_class.category_for_action(action)).to eq('security')
      end
    end

    it 'maps invitation actions to invitations' do
      %w[invitation_sent invitation_accepted invitation_declined].each do |action|
        expect(described_class.category_for_action(action)).to eq('invitations')
      end
    end

    it 'accepts symbols as input' do
      expect(described_class.category_for_action(:login)).to eq('auth')
    end

    it 'returns auth as default for unknown actions' do
      expect(described_class.category_for_action('nonexistent')).to eq('auth')
    end
  end

  describe '#description' do
    it 'returns login description without IP' do
      activity = build(:user_activity, :login, user: user, organisation: organisation)
      expect(activity.description).to include(I18n.t('models.user_activity.descriptions.login',
                                                     location_info: ''))
    end

    it 'returns login description with IP' do
      activity = build(:user_activity, :login, :with_request_info, user: user,
                                                                   organisation: organisation)
      expect(activity.description).to include(activity.ip_address)
    end

    it 'returns logout description' do
      activity = build(:user_activity, user: user, organisation: organisation,
                                       action: 'logout', category: 'auth')
      expect(activity.description).to eq(I18n.t('models.user_activity.descriptions.logout'))
    end

    # An organisation admin reads this log on the member's activity page, and a
    # member chooses which email the others see (User::EmailDisplay): the
    # description names no address, even when the change details are stored.
    it 'returns the generic email_changed description even with change details' do
      activity = build(:user_activity, user: user, organisation: organisation,
                                       action: 'email_changed', category: 'profile',
                                       attribute_changes: { 'email' => %w[old@test.com new@test.com] })
      expect(activity.description).to eq(I18n.t('models.user_activity.descriptions.email_changed'))
      expect(activity.description).not_to include('old@test.com', 'new@test.com')
    end

    it 'returns generic email_changed description without change details' do
      activity = build(:user_activity, user: user, organisation: organisation,
                                       action: 'email_changed', category: 'profile',
                                       attribute_changes: {})
      expect(activity.description).to eq(I18n.t('models.user_activity.descriptions.email_changed'))
    end

    it 'returns role_assigned description with role_name' do
      activity = build(:user_activity, :role_assigned, user: user, organisation: organisation)
      expect(activity.description).to include('Admin')
    end

    it 'returns role_assigned description without role_name' do
      activity = build(:user_activity, user: user, organisation: organisation,
                                       action: 'role_assigned', category: 'permissions',
                                       metadata: {})
      desc = activity.description
      expect(desc).not_to include("'")
    end

    it 'returns project_access description with project_name' do
      activity = build(:user_activity, user: user, organisation: organisation,
                                       action: 'project_access_granted', category: 'permissions',
                                       metadata: { 'project_name' => 'My Project' })
      expect(activity.description).to include('My Project')
    end

    it 'returns project_access description without project_name' do
      activity = build(:user_activity, user: user, organisation: organisation,
                                       action: 'project_access_granted', category: 'permissions',
                                       metadata: {})
      desc = activity.description
      no_name = I18n.t('models.user_activity.descriptions.project_access_no_name',
                       action_text: I18n.t('models.user_activity.descriptions.project_action_granted'))
      expect(desc).to eq(no_name)
    end

    it 'returns account_locked description with reason' do
      activity = build(:user_activity, :account_locked, user: user, organisation: organisation)
      expect(activity.description).to include('Too many failed attempts')
    end

    it 'returns account_locked description without reason' do
      activity = build(:user_activity, user: user, organisation: organisation,
                                       action: 'account_locked', category: 'security',
                                       metadata: {})
      desc = activity.description
      expect(desc).to eq(I18n.t('models.user_activity.descriptions.account_locked', lock_reason: ''))
    end

    it 'returns invitation description with email' do
      activity = build(:user_activity, :invitation_sent, user: user, organisation: organisation)
      expect(activity.description).to include('invited@example.com')
    end

    it 'returns invitation description without email' do
      activity = build(:user_activity, user: user, organisation: organisation,
                                       action: 'invitation_sent', category: 'invitations',
                                       metadata: {})
      no_email = I18n.t('models.user_activity.descriptions.invitation_no_email',
                        action_text: I18n.t('models.user_activity.descriptions.invitation_action_sent'))
      expect(activity.description).to eq(no_email)
    end

    it 'returns humanized action for unknown actions' do
      activity = build(:user_activity, user: user, organisation: organisation)
      # Bypass validation to test the else branch
      activity.action = 'some_unknown_thing'
      expect(activity.description).to eq('Some unknown thing')
    end

    described_class::ACTIONS.each do |key, action_value|
      it "returns a non-empty description for #{key}" do
        category = described_class.category_for_action(action_value)
        activity = build(:user_activity, user: user, organisation: organisation,
                                         action: action_value, category: category)
        expect(activity.description).to be_present
      end
    end
  end

  describe '#icon_class' do
    {
      'auth' => 'bi bi-shield-lock',
      'profile' => 'bi bi-person-circle',
      'permissions' => 'bi bi-key',
      'security' => 'bi bi-exclamation-triangle',
      'invitations' => 'bi bi-envelope'
    }.each do |category, expected_icon|
      it "returns #{expected_icon} for #{category}" do
        activity = build(:user_activity, user: user, organisation: organisation,
                                         action: 'login', category: category)
        expect(activity.icon_class).to eq(expected_icon)
      end
    end

    it 'returns default icon for unknown category' do
      activity = build(:user_activity, user: user, organisation: organisation)
      activity.category = 'unknown'
      expect(activity.icon_class).to eq('bi bi-activity')
    end
  end

  describe '#status_class' do
    it 'returns green for success' do
      activity = build(:user_activity, user: user, organisation: organisation, status: 'success')
      expect(activity.status_class).to eq('text-green-600')
    end

    it 'returns red for failed' do
      activity = build(:user_activity, user: user, organisation: organisation, status: 'failed')
      expect(activity.status_class).to eq('text-red-600')
    end

    it 'returns yellow for pending' do
      activity = build(:user_activity, user: user, organisation: organisation, status: 'pending')
      expect(activity.status_class).to eq('text-yellow-600')
    end

    it 'returns gray for unknown status' do
      activity = build(:user_activity, user: user, organisation: organisation)
      activity.status = 'unknown'
      expect(activity.status_class).to eq('text-gray-600')
    end
  end

  describe '#security_relevant?' do
    it 'is true for security category' do
      activity = build(:user_activity, :suspicious_activity, user: user, organisation: organisation)
      expect(activity).to be_security_relevant
    end

    it 'is true for login_failed even though category is auth' do
      activity = build(:user_activity, :login_failed, user: user, organisation: organisation)
      expect(activity).to be_security_relevant
    end

    it 'is true for account_locked' do
      activity = build(:user_activity, :account_locked, user: user, organisation: organisation)
      expect(activity).to be_security_relevant
    end

    it 'is false for normal login' do
      activity = build(:user_activity, :login, user: user, organisation: organisation)
      expect(activity).not_to be_security_relevant
    end

    it 'is false for profile_updated' do
      activity = build(:user_activity, :profile_updated, user: user, organisation: organisation)
      expect(activity).not_to be_security_relevant
    end
  end

  describe '#critical?' do
    it 'is true for account_locked' do
      activity = build(:user_activity, :account_locked, user: user, organisation: organisation)
      expect(activity).to be_critical
    end

    it 'is true for suspicious_activity' do
      activity = build(:user_activity, :suspicious_activity, user: user, organisation: organisation)
      expect(activity).to be_critical
    end

    it 'is true for permissions_changed' do
      activity = build(:user_activity, user: user, organisation: organisation,
                                       action: 'permissions_changed', category: 'permissions')
      expect(activity).to be_critical
    end

    it 'is true for role_assigned' do
      activity = build(:user_activity, :role_assigned, user: user, organisation: organisation)
      expect(activity).to be_critical
    end

    it 'is false for login' do
      activity = build(:user_activity, :login, user: user, organisation: organisation)
      expect(activity).not_to be_critical
    end

    it 'is false for role_removed' do
      activity = build(:user_activity, user: user, organisation: organisation,
                                       action: 'role_removed', category: 'permissions')
      expect(activity).not_to be_critical
    end
  end

  describe 'constants' do
    it 'has frozen ACTIONS hash' do
      expect(described_class::ACTIONS).to be_frozen
    end

    it 'has frozen CATEGORIES hash' do
      expect(described_class::CATEGORIES).to be_frozen
    end

    it 'has frozen STATUSES hash' do
      expect(described_class::STATUSES).to be_frozen
    end

    it 'has unique action values' do
      expect(described_class::ACTIONS.values.uniq.size).to eq(described_class::ACTIONS.values.size)
    end

    it 'has unique category values' do
      expect(described_class::CATEGORIES.values.uniq.size).to eq(described_class::CATEGORIES.values.size)
    end

    it 'maps every ACTIONS value in category_for_action without hitting the default' do
      described_class::ACTIONS.each_value do |action|
        category = described_class.category_for_action(action)
        next if %w[login logout login_failed registered
                   password_reset_requested password_reset_completed].include?(action)

        expect(category).not_to eq(described_class::CATEGORIES[:auth]),
                                "Action '#{action}' unexpectedly fell through to default auth category"
      end
    end
  end
end
