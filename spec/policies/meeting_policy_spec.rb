# frozen_string_literal: true

require 'rails_helper'

# MeetingPolicy mirrors NotePolicy: area-scoped access to Meeting via
# ProjectPolicy#area_access?(:meetings, …). Covers the full role matrix
# (admin/standard/reader/writer), per-project ProjectPermission overrides
# (grant-despite-no-role and no_access-beats-role), cross-tenant / inactive
# membership, and the Scope resolution.
RSpec.describe MeetingPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:meeting) { create(:meeting, project: project, organisation: organisation, creator: admin_user) }

  let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  let(:meetings_reader_role) do
    role = create(:role, title: 'Meetings Reader', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'read_access_meetings_all_projects', allowed: true)
    role
  end

  let(:meetings_writer_role) do
    role = create(:role, title: 'Meetings Writer', organisation: organisation)
    create(:permission, role: role, category: 'projects', action: 'write_access_meetings_all_projects', allowed: true)
    role
  end

  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  let(:standard_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
    user
  end

  let(:reader_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: meetings_reader_role, active: true)
    user
  end

  let(:writer_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: meetings_writer_role, active: true)
    user
  end

  let(:other_org_user) do
    other_role = create(:role, title: 'Other Org Role', organisation: other_organisation)
    user = create(:user)
    create(:membership, user: user, organisation: other_organisation, role: other_role, active: true)
    user
  end

  let(:inactive_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: meetings_reader_role, active: false)
    user
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'without a logged-in user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect { described_class.new(nil, meeting) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  describe 'for admin users' do
    subject { described_class.new(admin_user, meeting) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to permit_action(:new) }
    it { is_expected.to permit_action(:update) }
    it { is_expected.to permit_action(:edit) }
    it { is_expected.to permit_action(:destroy) }
  end

  describe 'for standard users without permissions' do
    subject { described_class.new(standard_user, meeting) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.not_to permit_action(:show) }
    it { is_expected.not_to permit_action(:create) }
    it { is_expected.not_to permit_action(:update) }
    it { is_expected.not_to permit_action(:destroy) }
  end

  describe 'for users with meetings read permission' do
    subject { described_class.new(reader_user, meeting) }

    it { is_expected.to permit_action(:show) }
    it { is_expected.not_to permit_action(:create) }
    it { is_expected.not_to permit_action(:update) }
    it { is_expected.not_to permit_action(:destroy) }
    # Slice 5: detection is write-shaped — reading meetings must NOT allow
    # sending transcripts to the LLM (the area gate lets readers through to
    # the policy, so this is the guard the request spec relies on).
    it { is_expected.not_to permit_action(:detect_participants) }
  end

  describe 'for users with meetings write permission' do
    subject { described_class.new(writer_user, meeting) }

    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to permit_action(:update) }
    it { is_expected.to permit_action(:destroy) }
    it { is_expected.to permit_action(:detect_participants) }
  end

  describe '#destroy?' do
    it 'permits destroy for admin' do
      expect(described_class.new(admin_user, meeting).destroy?).to be true
    end

    it 'permits destroy for writer' do
      expect(described_class.new(writer_user, meeting).destroy?).to be true
    end

    it 'denies destroy for reader (read does not imply delete)' do
      expect(described_class.new(reader_user, meeting).destroy?).to be false
    end

    it 'denies destroy for standard user' do
      expect(described_class.new(standard_user, meeting).destroy?).to be false
    end
  end

  describe 'per-project ProjectPermission overrides' do
    context 'when ProjectPermission grants read_only despite no role permission' do
      before { create(:project_permission, user: standard_user, project: project, meetings_access: 'read_only') }

      subject { described_class.new(standard_user, meeting) }

      it { is_expected.to permit_action(:show) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
    end

    context 'when ProjectPermission grants read_write despite no role permission' do
      before { create(:project_permission, user: standard_user, project: project, meetings_access: 'read_write') }

      subject { described_class.new(standard_user, meeting) }

      it { is_expected.to permit_action(:show) }
      it { is_expected.to permit_action(:create) }
      it { is_expected.to permit_action(:update) }
      it { is_expected.to permit_action(:destroy) }
    end

    context 'when ProjectPermission denies access despite role granting it' do
      before { create(:project_permission, user: writer_user, project: project, meetings_access: 'no_access') }

      subject { described_class.new(writer_user, meeting) }

      it 'no_access overrides the global role permission' do
        is_expected.not_to permit_action(:show)
        is_expected.not_to permit_action(:create)
        is_expected.not_to permit_action(:update)
        is_expected.not_to permit_action(:destroy)
      end
    end
  end

  describe 'cross-tenant and membership edge cases' do
    context 'when user belongs to a different organisation' do
      subject { described_class.new(other_org_user, meeting) }

      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
    end

    context 'when user has inactive membership' do
      subject { described_class.new(inactive_user, meeting) }

      it { is_expected.not_to permit_action(:show) }
      it { is_expected.not_to permit_action(:create) }
      it { is_expected.not_to permit_action(:update) }
      it { is_expected.not_to permit_action(:destroy) }
    end
  end

  describe MeetingPolicy::Scope do
    let(:project_b) { create(:project, organisation: organisation) }
    let!(:meeting_in_project) { create(:meeting, project: project, organisation: organisation, creator: admin_user) }
    let!(:meeting_in_project_b) { create(:meeting, project: project_b, organisation: organisation, creator: admin_user) }

    context 'for admin users' do
      it 'returns all meetings' do
        result = described_class.new(admin_user, Meeting).resolve
        expect(result).to include(meeting_in_project, meeting_in_project_b)
      end
    end

    context 'for users with global meetings read permission' do
      it 'returns meetings from all accessible projects' do
        result = described_class.new(reader_user, Meeting).resolve
        expect(result).to include(meeting_in_project, meeting_in_project_b)
      end
    end

    context 'for standard users without permissions' do
      it 'returns no meetings' do
        result = described_class.new(standard_user, Meeting).resolve
        expect(result).not_to include(meeting_in_project, meeting_in_project_b)
      end
    end

    context 'for users with per-project access to one project only' do
      before { create(:project_permission, user: standard_user, project: project, meetings_access: 'read_only') }

      it 'returns only meetings from the permitted project' do
        result = described_class.new(standard_user, Meeting).resolve
        expect(result).to include(meeting_in_project)
        expect(result).not_to include(meeting_in_project_b)
      end
    end

    context 'when ProjectPermission denies access despite role granting it' do
      before { create(:project_permission, user: reader_user, project: project, meetings_access: 'no_access') }

      it 'excludes meetings from the denied project' do
        result = described_class.new(reader_user, Meeting).resolve
        expect(result).not_to include(meeting_in_project)
        expect(result).to include(meeting_in_project_b)
      end
    end
  end
end
