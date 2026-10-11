# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolderPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  let(:admin_role) { create(:role, title: 'account_admin', organisation: organisation) }
  let(:standard_role) { create(:role, title: 'Standard User', organisation: organisation, is_default: true) }

  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  let(:owner) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
    user
  end

  let(:other_member) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
    user
  end

  let(:non_member) { create(:user) }

  let(:private_folder) do
    create(:smart_folder, user: owner, organisation: organisation, project: project, is_public: false)
  end

  let(:public_folder) do
    create(:smart_folder, user: owner, organisation: organisation, project: project, is_public: true, public_access_level: 0)
  end

  let(:public_copyable_folder) do
    create(:smart_folder, user: owner, organisation: organisation, project: project, is_public: true, public_access_level: 2)
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  # =========================================================================
  # index? — jeder authentifizierte User
  # =========================================================================
  describe '#index?' do
    it 'permits for any authenticated user' do
      expect(described_class.new(other_member, private_folder)).to permit_action(:index)
    end
  end

  # =========================================================================
  # show?
  # =========================================================================
  describe '#show?' do
    context 'private folder' do
      it 'permits for admin' do
        expect(described_class.new(admin_user, private_folder)).to permit_action(:show)
      end

      it 'permits for owner' do
        expect(described_class.new(owner, private_folder)).to permit_action(:show)
      end

      it 'denies for other member without share' do
        expect(described_class.new(other_member, private_folder)).not_to permit_action(:show)
      end

      it 'permits for user with explicit share' do
        create(:smart_folder_share, smart_folder: private_folder, user: other_member)
        expect(described_class.new(other_member, private_folder)).to permit_action(:show)
      end

      it 'denies for non-member' do
        expect(described_class.new(non_member, private_folder)).not_to permit_action(:show)
      end
    end

    context 'public folder' do
      it 'permits for any member' do
        expect(described_class.new(other_member, public_folder)).to permit_action(:show)
      end

      it 'permits for non-member (public check has no org guard)' do
        expect(described_class.new(non_member, public_folder)).to permit_action(:show)
      end
    end
  end

  # =========================================================================
  # create?
  # =========================================================================
  describe '#create?' do
    it 'permits for any authenticated user' do
      folder = build(:smart_folder, user: other_member, organisation: organisation, project: project)
      expect(described_class.new(other_member, folder)).to permit_action(:create)
    end
  end

  # =========================================================================
  # update?
  # =========================================================================
  describe '#update?' do
    it 'permits for admin' do
      expect(described_class.new(admin_user, private_folder)).to permit_action(:update)
    end

    it 'permits for owner' do
      expect(described_class.new(owner, private_folder)).to permit_action(:update)
    end

    it 'denies for other member without share' do
      expect(described_class.new(other_member, private_folder)).not_to permit_action(:update)
    end

    it 'permits for user with can_edit share' do
      create(:smart_folder_share, smart_folder: private_folder, user: other_member, can_edit: true)
      expect(described_class.new(other_member, private_folder)).to permit_action(:update)
    end

    it 'denies for user with read-only share' do
      create(:smart_folder_share, smart_folder: private_folder, user: other_member, can_edit: false)
      expect(described_class.new(other_member, private_folder)).not_to permit_action(:update)
    end

    it 'denies for non-member' do
      expect(described_class.new(non_member, private_folder)).not_to permit_action(:update)
    end
  end

  # =========================================================================
  # edit? — delegates to update?
  # =========================================================================
  describe '#edit?' do
    it 'permits for owner' do
      expect(described_class.new(owner, private_folder)).to permit_action(:edit)
    end

    it 'denies for other member without share' do
      expect(described_class.new(other_member, private_folder)).not_to permit_action(:edit)
    end
  end

  # =========================================================================
  # destroy?
  # =========================================================================
  describe '#destroy?' do
    it 'permits for admin' do
      expect(described_class.new(admin_user, private_folder)).to permit_action(:destroy)
    end

    it 'permits for owner' do
      expect(described_class.new(owner, private_folder)).to permit_action(:destroy)
    end

    it 'denies for other member even with can_edit share' do
      create(:smart_folder_share, smart_folder: private_folder, user: other_member, can_edit: true)
      expect(described_class.new(other_member, private_folder)).not_to permit_action(:destroy)
    end

    it 'denies for non-member' do
      expect(described_class.new(non_member, private_folder)).not_to permit_action(:destroy)
    end
  end

  # =========================================================================
  # share?
  # =========================================================================
  describe '#share?' do
    it 'permits for admin' do
      expect(described_class.new(admin_user, private_folder).share?).to be true
    end

    it 'permits for owner' do
      expect(described_class.new(owner, private_folder).share?).to be true
    end

    it 'denies for other member without share' do
      expect(described_class.new(other_member, private_folder).share?).to be false
    end

    it 'permits for user with can_share permission' do
      create(:smart_folder_share, smart_folder: private_folder, user: other_member, can_share: true)
      expect(described_class.new(other_member, private_folder).share?).to be true
    end

    it 'denies for user with share but without can_share' do
      create(:smart_folder_share, smart_folder: private_folder, user: other_member, can_share: false)
      expect(described_class.new(other_member, private_folder).share?).to be false
    end

    it 'denies for non-member' do
      expect(described_class.new(non_member, private_folder).share?).to be false
    end
  end

  # =========================================================================
  # publish? (visibility is the owner's call, or an admin's)
  # =========================================================================
  describe '#publish?' do
    it 'permits the owner and an admin' do
      expect(described_class.new(owner, private_folder).publish?).to be true
      expect(described_class.new(admin_user, private_folder).publish?).to be true
    end

    it 'denies shared editors, even with the share permission' do
      create(:smart_folder_share, smart_folder: private_folder, user: other_member, can_edit: true, can_share: true)
      expect(described_class.new(other_member, private_folder).publish?).to be false
    end
  end

  # =========================================================================
  # clone?
  # =========================================================================
  describe '#clone?' do
    context 'public folder with copy access level' do
      it 'permits for any authenticated user' do
        expect(described_class.new(other_member, public_copyable_folder).clone?).to be true
      end

      it 'permits even for non-member' do
        expect(described_class.new(non_member, public_copyable_folder).clone?).to be true
      end
    end

    context 'public folder without copy access level (view_only)' do
      it 'permits via show? fallback (public folder is visible)' do
        expect(described_class.new(other_member, public_folder).clone?).to be true
      end
    end

    context 'private folder' do
      it 'denies for user without show access' do
        expect(described_class.new(other_member, private_folder).clone?).to be false
      end

      it 'permits for owner (via show? fallback)' do
        expect(described_class.new(owner, private_folder).clone?).to be true
      end

      it 'permits for user with share (via show? fallback)' do
        create(:smart_folder_share, smart_folder: private_folder, user: other_member)
        expect(described_class.new(other_member, private_folder).clone?).to be true
      end
    end
  end

  # =========================================================================
  # Scope
  # =========================================================================
  describe SmartFolderPolicy::Scope do
    let!(:own_folder) { create(:smart_folder, user: other_member, organisation: organisation, project: project) }
    let!(:public_folder_scoped) { create(:smart_folder, user: owner, organisation: organisation, project: project, is_public: true) }
    let!(:private_other_folder) { create(:smart_folder, user: owner, organisation: organisation, project: project, is_public: false) }

    context 'as admin' do
      subject { described_class.new(admin_user, SmartFolder).resolve }

      let!(:admin_private) do
        create(:smart_folder, user: admin_user, organisation: organisation, project: project, is_public: false)
      end

      it 'includes the admin own private folders' do
        expect(subject).to include(admin_private)
      end

      it 'includes public folders' do
        expect(subject).to include(public_folder_scoped)
      end

      # Privacy contract: a private folder is owner/shared-only. An account admin
      # must NOT see other users' private personal folders in listings — they leaked
      # into the ticket filter bar as selectable pills (e.g. another user's "Meine Aufgaben").
      it 'does NOT include other users private folders' do
        expect(subject).not_to include(private_other_folder)
      end

      it 'includes another users private folder only when explicitly shared with the admin' do
        create(:smart_folder_share, smart_folder: private_other_folder, user: admin_user)
        expect(subject).to include(private_other_folder)
      end
    end

    context 'as standard user' do
      subject { described_class.new(other_member, SmartFolder).resolve }

      it 'includes own folders' do
        expect(subject).to include(own_folder)
      end

      it 'includes public folders' do
        expect(subject).to include(public_folder_scoped)
      end

      it 'excludes private folders from other users' do
        expect(subject).not_to include(private_other_folder)
      end

      it 'includes shared folders' do
        create(:smart_folder_share, smart_folder: private_other_folder, user: other_member)
        expect(subject).to include(private_other_folder)
      end
    end

    context 'as user with no folders' do
      let(:fresh_user) do
        user = create(:user)
        create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
        user
      end

      subject { described_class.new(fresh_user, SmartFolder).resolve }

      it 'returns only public folders' do
        expect(subject).to contain_exactly(public_folder_scoped)
      end
    end
  end

  # =========================================================================
  # nil user
  # =========================================================================
  describe 'meeting metadata permissions' do
    let!(:meeting_folder) { create(:smart_folder, user: owner, organisation: organisation, project: project, target_object_type: 'Meeting', is_public: true) }

    it 'requires meeting read access even for public or explicitly editable shared views' do
      create(:smart_folder_share, smart_folder: meeting_folder, user: other_member, can_edit: true, can_share: true)
      policy = described_class.new(other_member, meeting_folder)
      expect(policy).not_to be_show
      expect(policy).not_to be_update
      expect(policy).not_to be_share
      expect(policy).not_to be_clone
      expect(SmartFolderPolicy::Scope.new(other_member, SmartFolder).resolve).not_to include(meeting_folder)
      create(:project_permission, project: project, user: other_member, meetings_access: 'read_only')
      policy = described_class.new(other_member, meeting_folder)
      expect(policy).to be_show
      expect(policy).to be_update
      expect(SmartFolderPolicy::Scope.new(other_member, SmartFolder).resolve).to include(meeting_folder)
    end

    it 'refuses to clone a public-copy Meeting view without meeting access' do
      meeting_folder.update!(public_access_level: 2)
      expect(meeting_folder).to be_public_copy
      expect(described_class.new(other_member, meeting_folder)).not_to be_clone
    end
  end

  describe 'with nil user' do
    it 'raises Pundit::NotAuthorizedError' do
      expect do
        described_class.new(nil, private_folder)
      end.to raise_error(Pundit::NotAuthorizedError, 'must be logged in')
    end
  end
  describe 'organisation-wide meeting views' do
    let(:folder) { create(:smart_folder, user: owner, organisation: organisation, project: nil, target_object_type: 'Meeting', is_public: true) }

    it 'permits admins and readers of at least one meeting project' do
      expect(described_class.new(admin_user, folder)).to be_show
      expect(described_class.new(admin_user, folder)).to be_create
      expect(SmartFolderPolicy::Scope.new(admin_user, SmartFolder).resolve).to include(folder)
      expect(described_class.new(owner, folder)).not_to be_show
      expect(described_class.new(owner, folder)).not_to be_create
      expect(SmartFolderPolicy::Scope.new(owner, SmartFolder).resolve).not_to include(folder)
      create(:project_permission, project: project, user: owner, meetings_access: 'read_only')
      expect(described_class.new(owner, folder)).to be_show
      expect(described_class.new(owner, folder)).to be_create
      expect(described_class.new(owner, folder)).to be_destroy
      expect(SmartFolderPolicy::Scope.new(owner, SmartFolder).resolve).to include(folder)
    end
  end
end
