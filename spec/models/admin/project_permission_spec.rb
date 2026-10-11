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
#  meetings_access      :integer          default(0), not null
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

RSpec.describe Admin::ProjectPermission, type: :model do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  before { ActsAsTenant.current_tenant = organisation }

  # Helper: creates Admin::ProjectPermission with IDs instead of objects,
  # to avoid AssociationTypeMismatch (User vs Admin::User).
  def create_permission(attrs = {})
    attrs[:user_id] ||= (attrs.delete(:user) || user).id
    attrs[:project_id] ||= (attrs.delete(:project) || project).id
    described_class.create!(attrs)
  end

  # ===========================================================================
  # Table & Model Configuration
  # ===========================================================================
  describe 'table configuration' do
    it 'uses the project_permissions table' do
      expect(described_class.table_name).to eq('project_permissions')
    end

    it 'strips Admin namespace from model_name for routing' do
      expect(described_class.model_name.to_s).to eq('ProjectPermission')
    end

    it 'does not declare acts_as_tenant directly' do
      expect(described_class).not_to respond_to(:scoped_by_tenant?)
    end
  end

  # ===========================================================================
  # Constants
  # ===========================================================================
  describe 'constants' do
    describe 'ACCESS_AREAS' do
      # Agreement with the owning model, NOT a literal of its own. The previous
      # version of this example pinned a hand-written six-element list, so the
      # constant was only ever compared against a copy of itself: when `meetings`
      # and `processes` were added to ProjectPermission this file stayed green
      # while the admin user detail page 500ed in production.
      it 'is the area list of the tenant-side model, not a second copy of it' do
        expect(described_class::ACCESS_AREAS).to eq(ProjectPermission.access_areas)
      end

      # The concrete regression, spelled out so the agreement above cannot pass
      # vacuously if both sides were ever shrunk together.
      it 'includes the area whose absence broke the admin user page' do
        expect(described_class::ACCESS_AREAS).to include(:meetings)
      end

      it 'is frozen' do
        expect(described_class::ACCESS_AREAS).to be_frozen
      end
    end

    describe 'ACCESS_CSS_CLASSES' do
      it 'maps all three access levels to CSS classes' do
        expect(described_class::ACCESS_CSS_CLASSES.keys).to contain_exactly('read_write', 'read_only', 'no_access')
      end

      it 'is frozen' do
        expect(described_class::ACCESS_CSS_CLASSES).to be_frozen
      end
    end
  end

  # ===========================================================================
  # Associations
  # ===========================================================================
  describe 'associations' do
    it { is_expected.to belong_to(:user).class_name('Admin::User') }
    it { is_expected.to belong_to(:project).class_name('Admin::Project') }
  end

  # ===========================================================================
  # Enums
  # ===========================================================================
  describe 'enums' do
    described_class::ACCESS_AREAS.each do |area|
      describe "#{area}_access" do
        it "defines no_access, read_only, read_write for #{area}" do
          expect(described_class.public_send(:"#{area}_accesses")).to eq(
            'no_access' => 0, 'read_only' => 1, 'read_write' => 2
          )
        end

        it 'defaults to no_access' do
          permission = described_class.new
          expect(permission.public_send(:"#{area}_access")).to eq('no_access')
        end

        it 'generates prefixed predicate methods' do
          permission = create_permission("#{area}_access": 'read_write')
          expect(permission.public_send(:"#{area}_access_read_write?")).to be true
          expect(permission.public_send(:"#{area}_access_no_access?")).to be false
        end
      end
    end

    it 'rejects invalid enum values' do
      expect do
        described_class.new(tickets_access: 'admin')
      end.to raise_error(ArgumentError, /is not a valid tickets_access/)
    end
  end

  # ===========================================================================
  # Default Scope (Soft Delete)
  # ===========================================================================
  describe 'default scope (soft delete)' do
    it 'excludes soft-deleted records from default queries' do
      active = create_permission
      create_permission(user: create(:user), deleted_at: 1.day.ago)

      expect(described_class.all).to contain_exactly(active)
    end

    it 'includes soft-deleted records with unscoped' do
      active = create_permission
      deleted = create_permission(user: create(:user), deleted_at: 1.day.ago)

      expect(described_class.unscoped.where(project_id: project.id)).to contain_exactly(active, deleted)
    end

    it 'treats records without deleted_at as active' do
      permission = create_permission
      expect(permission.deleted_at).to be_nil
      expect(described_class.all).to include(permission)
    end
  end

  # ===========================================================================
  # Scopes
  # ===========================================================================
  describe 'scopes' do
    describe '.with_any_access' do
      it 'returns records where at least one area has access' do
        with_access = create_permission(tickets_access: 'read_only')
        create_permission(user: create(:user)) # all no_access

        expect(described_class.with_any_access).to contain_exactly(with_access)
      end

      it 'returns records where only members_access is set' do
        members_only = create_permission(members_access: 'read_write')
        expect(described_class.with_any_access).to contain_exactly(members_only)
      end

      it 'returns records where multiple areas have access' do
        multi = create_permission(tickets_access: 'read_write', notes_access: 'read_only')
        expect(described_class.with_any_access).to contain_exactly(multi)
      end

      it 'excludes records where all areas are no_access' do
        create_permission # all defaults = no_access
        expect(described_class.with_any_access).to be_empty
      end
    end

    describe '.ordered_by_project' do
      it 'orders by project name ascending' do
        project_b = ActsAsTenant.with_tenant(organisation) { create(:project, name: 'Beta', organisation: organisation) }
        project_a = ActsAsTenant.with_tenant(organisation) { create(:project, name: 'Alpha', organisation: organisation) }
        perm_b = create_permission(project: project_b)
        perm_a = create_permission(user: create(:user), project: project_a)

        expect(described_class.ordered_by_project.to_a).to eq([perm_a, perm_b])
      end
    end

    describe '.ordered_by_user' do
      it 'orders by user email ascending' do
        user_z = create(:user, email: 'zara@example.com')
        user_a = create(:user, email: 'alice@example.com')
        perm_z = create_permission(user: user_z)
        other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
        perm_a = create_permission(user: user_a, project: other_project)

        expect(described_class.ordered_by_user.to_a).to eq([perm_a, perm_z])
      end
    end
  end

  # ===========================================================================
  # Delegation Methods
  # ===========================================================================
  describe 'delegation methods' do
    describe '#user_email' do
      it 'returns the user email' do
        permission = create_permission
        expect(permission.user_email).to eq(user.email)
      end
    end

    describe '#project_name' do
      it 'returns the project name' do
        permission = create_permission
        expect(permission.project_name).to eq(project.name)
      end
    end

    describe '#organisation_name' do
      it 'returns the organisation name via project' do
        permission = create_permission
        expect(permission.organisation_name).to eq(organisation.name)
      end
    end
  end

  # ===========================================================================
  # Access Text Methods (dynamically generated)
  # ===========================================================================
  describe 'access text methods' do
    described_class::ACCESS_AREAS.each do |area|
      describe "##{area}_access_text" do
        it 'returns humanized no_access' do
          permission = create_permission("#{area}_access": 'no_access')
          expect(permission.public_send(:"#{area}_access_text")).to eq('No access')
        end

        it 'returns humanized read_only' do
          permission = create_permission("#{area}_access": 'read_only')
          expect(permission.public_send(:"#{area}_access_text")).to eq('Read only')
        end

        it 'returns humanized read_write' do
          permission = create_permission("#{area}_access": 'read_write')
          expect(permission.public_send(:"#{area}_access_text")).to eq('Read write')
        end
      end
    end
  end

  # ===========================================================================
  # CSS Class Methods (dynamically generated)
  # ===========================================================================
  describe 'CSS class methods' do
    described_class::ACCESS_AREAS.each do |area|
      describe "##{area}_access_css_class" do
        it 'returns gray for no_access' do
          permission = create_permission("#{area}_access": 'no_access')
          expect(permission.public_send(:"#{area}_access_css_class")).to eq('bg-gray-100 text-gray-800')
        end

        it 'returns yellow for read_only' do
          permission = create_permission("#{area}_access": 'read_only')
          expect(permission.public_send(:"#{area}_access_css_class")).to eq('bg-yellow-100 text-yellow-800')
        end

        it 'returns green for read_write' do
          permission = create_permission("#{area}_access": 'read_write')
          expect(permission.public_send(:"#{area}_access_css_class")).to eq('bg-green-100 text-green-800')
        end
      end
    end
  end

  # ===========================================================================
  # #access_summary
  # ===========================================================================
  describe '#access_summary' do
    # This is what the admin user detail view renders, so it has to cover every
    # area the domain knows -- a missing key there is a row the operator never
    # sees.
    it 'returns a hash with all access areas' do
      permission = create_permission
      summary = permission.access_summary

      expect(summary.keys).to contain_exactly(:tickets, :notes, :chats, :documents, :members,
                                              :documentation, :meetings)
    end

    it 'includes level, text, and css for each area' do
      permission = create_permission(tickets_access: 'read_write')
      summary = permission.access_summary

      expect(summary[:tickets]).to eq(
        level: 'read_write',
        text: 'Read write',
        css: 'bg-green-100 text-green-800'
      )
    end

    it 'handles mixed access levels correctly' do
      permission = create_permission(
        tickets_access: 'read_write',
        notes_access: 'read_only',
        chats_access: 'no_access',
        documents_access: 'read_write',
        members_access: 'read_only'
      )
      summary = permission.access_summary

      expect(summary[:tickets][:level]).to eq('read_write')
      expect(summary[:notes][:level]).to eq('read_only')
      expect(summary[:chats][:level]).to eq('no_access')
      expect(summary[:documents][:level]).to eq('read_write')
      expect(summary[:members][:level]).to eq('read_only')
    end

    it 'shows all no_access when permission has no access' do
      permission = create_permission
      summary = permission.access_summary

      summary.each_value do |entry|
        expect(entry[:level]).to eq('no_access')
        expect(entry[:css]).to eq('bg-gray-100 text-gray-800')
      end
    end
  end

  # ===========================================================================
  # #has_any_access?
  # ===========================================================================
  describe '#has_any_access?' do
    it 'returns false when all areas are no_access' do
      permission = create_permission
      expect(permission.has_any_access?).to be false
    end

    it 'returns true when at least one area has read_only' do
      permission = create_permission(notes_access: 'read_only')
      expect(permission.has_any_access?).to be true
    end

    it 'returns true when at least one area has read_write' do
      permission = create_permission(documents_access: 'read_write')
      expect(permission.has_any_access?).to be true
    end

    it 'returns true when only members_access has access' do
      permission = create_permission(members_access: 'read_only')
      expect(permission.has_any_access?).to be true
    end

    it 'returns true when all areas have access' do
      permission = create_permission(
        tickets_access: 'read_write',
        notes_access: 'read_write',
        chats_access: 'read_write',
        documents_access: 'read_write',
        members_access: 'read_write'
      )
      expect(permission.has_any_access?).to be true
    end

    described_class::ACCESS_AREAS.each do |area|
      it "detects access when only #{area} is set" do
        permission = create_permission("#{area}_access": 'read_write')
        expect(permission.has_any_access?).to be true
      end
    end
  end

  # ===========================================================================
  # Factory Traits
  # ===========================================================================
  describe 'factory traits' do
    it 'creates with full_access trait' do
      permission = create(:admin_project_permission, :full_access,
                          user_id: user.id, project_id: project.id)

      described_class::ACCESS_AREAS.each do |area|
        expect(permission.public_send(:"#{area}_access")).to eq('read_write')
      end
    end

    it 'creates with read_only_access trait' do
      permission = create(:admin_project_permission, :read_only_access,
                          user_id: user.id, project_id: project.id)

      described_class::ACCESS_AREAS.each do |area|
        expect(permission.public_send(:"#{area}_access")).to eq('read_only')
      end
    end

    it 'creates with soft_deleted trait' do
      permission = build(:admin_project_permission, :soft_deleted,
                         user_id: user.id, project_id: project.id)
      expect(permission.deleted_at).to be_present
    end

    it 'creates with mixed_access trait' do
      permission = create(:admin_project_permission, :mixed_access,
                          user_id: user.id, project_id: project.id)

      expect(permission.tickets_access).to eq('read_write')
      expect(permission.notes_access).to eq('read_only')
      expect(permission.chats_access).to eq('no_access')
      expect(permission.documents_access).to eq('read_write')
      expect(permission.members_access).to eq('read_only')
    end
  end

  # ===========================================================================
  # Edge Cases
  # ===========================================================================
  describe 'edge cases' do
    it 'enforces unique constraint on user_id + project_id at DB level' do
      create_permission
      duplicate = described_class.new(user_id: user.id, project_id: project.id)

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows same user with different projects' do
      create_permission
      other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      other_perm = create_permission(project_id: other_project.id)

      expect(other_perm).to be_persisted
    end

    it 'allows same project with different users' do
      create_permission
      other_user = create(:user)
      other_perm = create_permission(user_id: other_user.id)

      expect(other_perm).to be_persisted
    end

    it 'prevents duplicate user+project even if one is soft-deleted (DB-level unique index)' do
      first = create_permission
      first.update_column(:deleted_at, 1.day.ago)

      expect do
        create_permission
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
