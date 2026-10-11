# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ViewConfigurationPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  let(:admin_role) do
    create(:role, title: 'account_admin', organisation: organisation)
  end

  let(:standard_role) do
    create(:role, title: 'Standard User', organisation: organisation, is_default: true)
  end

  let(:owner) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  let(:other_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  let(:standard_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
    user
  end

  let(:view_configuration) do
    create(:view_configuration, user: owner, project: project, organisation: organisation)
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  # =========================================================================
  # edit?
  # =========================================================================
  describe '#edit?' do
    context 'when user owns the view configuration' do
      subject { described_class.new(owner, view_configuration) }

      it { is_expected.to permit_action(:edit) }
    end

    context 'when user does NOT own the view configuration' do
      subject { described_class.new(other_user, view_configuration) }

      it { is_expected.not_to permit_action(:edit) }
    end

    context 'when admin tries to edit another users config' do
      subject { described_class.new(other_user, view_configuration) }

      it 'denies access even for admins (no admin bypass)' do
        expect(subject).not_to permit_action(:edit)
      end
    end

    context 'when standard user tries to edit another users config' do
      subject { described_class.new(standard_user, view_configuration) }

      it { is_expected.not_to permit_action(:edit) }
    end
  end

  # =========================================================================
  # update? (delegates to edit?)
  # =========================================================================
  describe '#update?' do
    context 'when user owns the view configuration' do
      subject { described_class.new(owner, view_configuration) }

      it { is_expected.to permit_action(:update) }
    end

    context 'when user does NOT own the view configuration' do
      subject { described_class.new(other_user, view_configuration) }

      it { is_expected.not_to permit_action(:update) }
    end

    context 'when standard user tries to update another users config' do
      subject { described_class.new(standard_user, view_configuration) }

      it { is_expected.not_to permit_action(:update) }
    end
  end

  # =========================================================================
  # create?
  # =========================================================================
  describe '#create?' do
    context 'when user has access to the project (admin)' do
      let(:new_config) { build(:view_configuration, user: owner, project: project, organisation: organisation) }
      subject { described_class.new(owner, new_config) }

      it { is_expected.to permit_action(:create) }
    end

    context 'when user has project-specific read permission' do
      let(:new_config) { build(:view_configuration, user: standard_user, project: project, organisation: organisation) }
      subject { described_class.new(standard_user, new_config) }

      before do
        ProjectPermission.create!(
          user: standard_user,
          project: project,
          tickets_access: 'read_only',
          notes_access: 'no_access',
          chats_access: 'no_access',
          documents_access: 'no_access'
        )
      end

      it { is_expected.to permit_action(:create) }
    end

    context 'when user has NO access to the project' do
      let(:new_config) { build(:view_configuration, user: standard_user, project: project, organisation: organisation) }
      subject { described_class.new(standard_user, new_config) }

      it { is_expected.not_to permit_action(:create) }
    end

    context 'when project belongs to a different organisation' do
      let(:other_org) { create(:organisation) }
      let(:other_project) do
        ActsAsTenant.with_tenant(other_org) { create(:project, organisation: other_org) }
      end

      context 'with a non-admin user who has no membership in the other org' do
        let(:new_config) { build(:view_configuration, user: standard_user, project: other_project, organisation: other_org) }
        subject { described_class.new(standard_user, new_config) }

        it 'denies create because user has no access to foreign project' do
          expect(subject).not_to permit_action(:create)
        end
      end

      context 'with an admin of the current org (cross-tenant boundary)' do
        let(:new_config) { build(:view_configuration, user: owner, project: other_project, organisation: other_org) }
        subject { described_class.new(owner, new_config) }

        it 'denies create even for admins — acts_as_tenant prevents cross-org access' do
          expect(subject).not_to permit_action(:create)
        end
      end
    end
  end

  # =========================================================================
  # new? (delegates to create? via ApplicationPolicy)
  # =========================================================================
  describe '#new?' do
    context 'when user has project access' do
      let(:new_config) { build(:view_configuration, user: owner, project: project, organisation: organisation) }
      subject { described_class.new(owner, new_config) }

      it { is_expected.to permit_action(:new) }
    end

    context 'when user has no project access' do
      let(:new_config) { build(:view_configuration, user: standard_user, project: project, organisation: organisation) }
      subject { described_class.new(standard_user, new_config) }

      it { is_expected.not_to permit_action(:new) }
    end
  end

  # =========================================================================
  # Inherited actions that default to false
  # =========================================================================
  describe 'inherited defaults from ApplicationPolicy' do
    subject { described_class.new(owner, view_configuration) }

    describe '#index?' do
      it { is_expected.not_to permit_action(:index) }
    end

    describe '#show?' do
      it { is_expected.not_to permit_action(:show) }
    end

    describe '#destroy?' do
      it { is_expected.not_to permit_action(:destroy) }
    end
  end

  # =========================================================================
  # Scope
  # =========================================================================
  describe ViewConfigurationPolicy::Scope do
    let!(:own_config) do
      create(:view_configuration, user: owner, project: project, organisation: organisation)
    end

    let!(:other_config) do
      create(:view_configuration, user: other_user, project: project, organisation: organisation, view_type: 'notes')
    end

    subject { described_class.new(owner, ViewConfiguration).resolve }

    it 'returns only the users own view configurations' do
      expect(subject).to include(own_config)
      expect(subject).not_to include(other_config)
    end

    it 'does not leak configs from other users' do
      expect(subject.count).to eq(1)
    end

    context 'when user has multiple configs across projects' do
      let(:project2) { create(:project, organisation: organisation) }
      let!(:second_config) do
        create(:view_configuration, user: owner, project: project2, organisation: organisation)
      end

      it 'returns all of the users own configs' do
        expect(subject).to contain_exactly(own_config, second_config)
      end
    end

    context 'when user has no configs' do
      subject { described_class.new(standard_user, ViewConfiguration).resolve }

      it 'returns an empty relation' do
        expect(subject).to be_empty
      end
    end
  end

  # =========================================================================
  # Edge case: nil user
  # =========================================================================
  describe 'with nil user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect do
        described_class.new(nil, view_configuration)
      end.to raise_error(Pundit::NotAuthorizedError, 'must be logged in')
    end
  end

  # =========================================================================
  # Edge case: Scope with nil user
  # =========================================================================
  describe 'Scope with nil user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect do
        ViewConfigurationPolicy::Scope.new(nil, ViewConfiguration)
      end.to raise_error(Pundit::NotAuthorizedError, 'must be logged in')
    end
  end
end
