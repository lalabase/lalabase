# frozen_string_literal: true

# == Schema Information
#
# Table name: project_permissions
#
#  id                   :uuid             not null, primary key
#  chats_access         :integer          default("no_access"), not null
#  deleted_at           :datetime
#  documentation_access :integer          default("no_access"), not null
#  documents_access     :integer          default("no_access"), not null
#  last_accessed_at     :datetime
#  meetings_access      :integer          default("no_access"), not null
#  members_access       :integer          default("no_access"), not null
#  notes_access         :integer          default("no_access"), not null
#  tickets_access       :integer          default("no_access"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  project_id           :uuid             not null
#  user_id              :uuid             not null
#
# Indexes
#
#  index_project_permissions_on_deleted_at              (deleted_at)
#  index_project_permissions_on_user_id_and_project_id  (user_id,project_id) UNIQUE
#  index_project_permissions_on_user_last_accessed      (user_id,last_accessed_at)
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
require 'rails_helper'

RSpec.describe ProjectPermission, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project, organisation: organisation)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  after do
    ActsAsTenant.current_tenant = nil
  end

  describe 'associations' do
  end

  describe 'validations' do
    it 'validates uniqueness of user_id scoped to project_id for active records' do
      # Create a permission first to test uniqueness constraint
      create(:project_permission, user: user, project: project)

      # Trying to create duplicate should fail
      duplicate_permission = build(:project_permission, user: user, project: project)
      expect(duplicate_permission).not_to be_valid
      expect(duplicate_permission.errors[:user_id]).to be_present
    end

    it 'allows creating new permission after soft-deleting previous one' do
      # Create first permission
      permission = create(:project_permission, user: user, project: project)

      # Soft delete it
      permission.update(deleted_at: Time.current)

      # Now we should be able to create a new one for the same user/project
      new_permission = build(:project_permission, user: user, project: project)
      expect(new_permission).to be_valid
    end
  end

  describe 'enum definitions' do
    it 'defines enums with correct values' do
      # Testing one enum to verify the pattern
      expect(ProjectPermission.tickets_accesses).to eq({
                                                         no_access: 0,
                                                         read_only: 1,
                                                         read_write: 2
                                                       })
    end

    it 'defines all access areas correctly' do
      expect(ProjectPermission.access_areas).to contain_exactly(
        :tickets, :notes, :chats, :documents, :members, :documentation, :meetings
      )
    end
  end

  describe 'default values' do
    it 'sets default values for access fields' do
      permission = ProjectPermission.new(user: user, project: project)

      # Check that all access fields default to no_access
      ProjectPermission.access_areas.each do |area|
        expect(permission.public_send("#{area}_access")).to eq('no_access')
      end
    end
  end

  describe 'soft delete' do
    it 'is not returned in queries after soft delete' do
      permission = create(:project_permission, user: user, project: project)

      # Before soft delete, we can find it
      expect(ProjectPermission.find_by(user: user, project: project)).to eq(permission)

      # After soft delete, it should not be found with default scope
      permission.update(deleted_at: Time.current)
      expect(ProjectPermission.find_by(user: user, project: project)).to be_nil

      # But should be found when unscoped
      expect(ProjectPermission.unscoped.find_by(user: user, project: project)).to eq(permission)
    end
  end

  describe '#can?' do
    context 'with no_access setting' do
      let(:permission) { create(:project_permission, tickets_access: 'no_access') }

      it 'returns false for read action' do
        expect(permission.can?(:read, :tickets)).to be_falsey
      end

      it 'returns false for write action' do
        expect(permission.can?(:write, :tickets)).to be_falsey
      end
    end

    context 'with read_only setting' do
      let(:permission) { create(:project_permission, notes_access: 'read_only') }

      it 'returns true for read action' do
        expect(permission.can?(:read, :notes)).to be_truthy
      end

      it 'returns false for write action' do
        expect(permission.can?(:write, :notes)).to be_falsey
      end
    end

    context 'with read_write setting' do
      let(:permission) { create(:project_permission, chats_access: 'read_write') }

      it 'returns true for read action' do
        expect(permission.can?(:read, :chats)).to be_truthy
      end

      it 'returns true for write action' do
        expect(permission.can?(:write, :chats)).to be_truthy
      end
    end

    context 'with invalid area' do
      let(:permission) { create(:project_permission) }

      it 'returns false for invalid area' do
        expect(permission.can?(:read, :invalid_area)).to be_falsey
      end
    end

    context 'with invalid action' do
      let(:permission) { create(:project_permission, documents_access: 'read_write') }

      it 'returns false for invalid action' do
        expect(permission.can?(:invalid_action, :documents)).to be_falsey
      end
    end
  end

  describe 'with different access levels for different areas' do
    let(:permission) do
      create(:project_permission,
             tickets_access: 'read_write',
             notes_access: 'read_only',
             chats_access: 'no_access',
             documents_access: 'read_write')
    end

    it 'correctly determines read permissions for all areas' do
      expect(permission.can?(:read, :tickets)).to be_truthy
      expect(permission.can?(:read, :notes)).to be_truthy
      expect(permission.can?(:read, :chats)).to be_falsey
      expect(permission.can?(:read, :documents)).to be_truthy
    end

    it 'correctly determines write permissions for all areas' do
      expect(permission.can?(:write, :tickets)).to be_truthy
      expect(permission.can?(:write, :notes)).to be_falsey
      expect(permission.can?(:write, :chats)).to be_falsey
      expect(permission.can?(:write, :documents)).to be_truthy
    end
  end
  # Two rules decide whether a saved row subscribes its user to the project:
  # skip_auto_subscribe (a blocking row must not subscribe the person it locks
  # out) and #revived? (a restored row IS a grant and has to subscribe, even
  # though update! fires no create callback).
  #
  # These assert the PREDICATES and the callback DECLARATIONS, not the effect.
  # This suite cannot observe after_create_commit / after_update_commit at all:
  # measured on the current tree, auto_subscribe_user is never reached, so any
  # cell that waited for a real subscription would pass with the callbacks
  # deleted. Deleting the guards here is what these cells break on.
  describe 'auto-subscribe guards' do
    let(:organisation) { create(:organisation) }
    let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:user) { create(:user) }

    # ActiveSupport keys the :commit chain by filter, so a second declaration
    # naming the SAME method silently replaces the first. Reading the chain back
    # is what catches that; it cost the create-time subscription once already.
    def callback_for(filter)
      described_class._commit_callbacks.find { |cb| cb.filter == filter }
    end

    def conditions_of(callback)
      Array(callback&.instance_variable_get(:@if)).select { |c| c.is_a?(Symbol) } +
        Array(callback&.instance_variable_get(:@unless)).select { |c| c.is_a?(Symbol) }
    end

    describe '#revived?' do
      subject(:permission) do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: user, project: project, tickets_access: 'read_write')
        end
      end

      it 'is true right after an archived row is brought back' do
        permission.update!(deleted_at: Time.current)
        permission.update!(deleted_at: nil)

        expect(permission.revived?).to be(true)
      end

      it 'is false when the same save was a soft delete' do
        permission.update!(deleted_at: Time.current)

        expect(permission.revived?).to be(false)
      end

      it 'is false for a save that did not touch deleted_at' do
        permission.update!(tickets_access: 'read_only')

        expect(permission.revived?).to be(false)
      end

      it 'is false when the writer marked the row as a block' do
        permission.update!(deleted_at: Time.current)
        permission.skip_auto_subscribe = true
        permission.update!(deleted_at: nil)

        expect(permission.revived?).to be(false)
      end
    end

    it 'guards the create-time subscription with skip_auto_subscribe' do
      expect(conditions_of(callback_for(:auto_subscribe_user))).to include(:skip_auto_subscribe)
    end

    it 'subscribes on a revival too, which update! alone would never do' do
      expect(conditions_of(callback_for(:auto_subscribe_revived_user))).to include(:revived?)
    end

    it 'keeps both hooks, because one filter name would overwrite the other' do
      filters = described_class._commit_callbacks.map(&:filter)

      expect(filters).to include(:auto_subscribe_user, :auto_subscribe_revived_user)
    end
  end
end
