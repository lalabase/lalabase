# frozen_string_literal: true

# == Schema Information
#
# Table name: time_session_permissions
#
#  id             :uuid             not null, primary key
#  can_create_own :boolean          default(TRUE), not null
#  can_delete_all :boolean          default(FALSE), not null
#  can_delete_own :boolean          default(TRUE), not null
#  can_edit_all   :boolean          default(FALSE), not null
#  can_edit_own   :boolean          default(TRUE), not null
#  can_view_all   :boolean          default(FALSE), not null
#  can_view_own   :boolean          default(TRUE), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  project_id     :uuid             not null
#  user_id        :uuid             not null
#
# Indexes
#
#  index_time_session_permissions_on_project     (project_id)
#  index_time_session_permissions_on_project_id  (project_id)
#  index_time_session_permissions_on_user_id     (user_id)
#  index_time_session_permissions_unique         (user_id,project_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
require 'rails_helper'

RSpec.describe TimeSessionPermission, type: :model do
  let(:organisation) { create(:organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
  end
  describe 'associations' do
  end

  describe 'validations' do
    subject { create(:time_session_permission) }
    it { should validate_uniqueness_of(:user_id).scoped_to(:project_id).ignoring_case_sensitivity }
  end

  describe 'defaults' do
    let(:permission) { TimeSessionPermission.new }

    it 'sets default values for new records' do
      expect(permission.can_create_own).to be true
      expect(permission.can_view_own).to be true
      expect(permission.can_edit_own).to be true
      expect(permission.can_delete_own).to be true
      expect(permission.can_view_all).to be false
      expect(permission.can_edit_all).to be false
      expect(permission.can_delete_all).to be false
    end
  end

  describe '#can?' do
    let(:permission) { create(:time_session_permission) }

    context 'with own scope' do
      it 'returns correct values for own permissions' do
        expect(permission.can?(:create, :own)).to be true
        expect(permission.can?(:view, :own)).to be true
        expect(permission.can?(:edit, :own)).to be true
        expect(permission.can?(:delete, :own)).to be true
      end
    end

    context 'with all scope' do
      before do
        permission.update!(
          can_view_all: true,
          can_edit_all: true,
          can_delete_all: true
        )
      end

      it 'returns correct values for all permissions' do
        expect(permission.can?(:view, :all)).to be true
        expect(permission.can?(:edit, :all)).to be true
        expect(permission.can?(:delete, :all)).to be true
      end
    end

    it 'returns false for invalid combinations' do
      expect(permission.can?(:invalid_action, :own)).to be false
      expect(permission.can?(:view, :invalid_scope)).to be false
    end
  end

  describe '#permission_summary' do
    let(:permission) { create(:time_session_permission) }

    it 'returns correct summary for default permissions' do
      expect(permission.permission_summary).to eq(
        'Eigene erstellen, Eigene ansehen, Eigene bearbeiten, Eigene löschen'
      )
    end

    it 'includes all permissions when enabled' do
      permission.update!(
        can_view_all: true,
        can_edit_all: true,
        can_delete_all: true
      )

      expect(permission.permission_summary).to include('Alle ansehen')
      expect(permission.permission_summary).to include('Alle bearbeiten')
      expect(permission.permission_summary).to include('Alle löschen')
    end
  end

  describe 'scopes' do
    describe '.for_organisation' do
      let(:other_organisation) { create(:organisation) }
      let(:project) { create(:project, organisation: organisation) }
      let(:other_project) { create(:project, organisation: other_organisation) }
      let(:user) { create(:user) }

      let!(:permission1) { create(:time_session_permission, user: user, project: project) }
      let!(:permission2) do
        ActsAsTenant.with_tenant(other_organisation) do
          create(:time_session_permission, user: user, project: other_project)
        end
      end

      it 'returns only permissions for projects in the organisation' do
        result = TimeSessionPermission.for_organisation(organisation)
        expect(result).to include(permission1)
        expect(result).not_to include(permission2)
      end
    end
  end
end
