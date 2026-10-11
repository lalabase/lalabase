# frozen_string_literal: true

# =============================================================================
# Admin::Project Model
# =============================================================================
# Special version of the Project model for admin-backend operations.
# Uses the same table as the regular Project model, but without
# acts_as_tenant restrictions, for an administrative overview across all tenants.
#
# IMPORTANT: This model may only be used in the admin area!
# For all frontend operations, the regular Project model must be used.
# =============================================================================

# == Schema Information
#
# Table name: projects
#
#  id              :uuid             not null, primary key
#  archived_at     :datetime
#  description     :text
#  name            :string
#  repository      :text
#  settings        :jsonb            not null
#  system_kind     :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  archived_by_id  :uuid
#  organisation_id :uuid             not null
#
# Indexes
#
#  idx_projects_on_org_and_system_kind  (organisation_id,system_kind) UNIQUE WHERE (system_kind IS NOT NULL)
#  index_projects_on_archived_at        (archived_at)
#  index_projects_on_organisation_id    (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (archived_by_id => users.id)
#
module Admin
  class Project < ApplicationRecord
    self.table_name = 'projects'

    SHORT_DESCRIPTION_LIMIT = 100

    REPOSITORY_PROVIDERS = {
      'github.com' => 'GitHub',
      'gitlab.com' => 'GitLab',
      'bitbucket.org' => 'Bitbucket'
    }.freeze

    def self.model_name
      ActiveModel::Name.new(self, nil, 'Project')
    end

    # NO acts_as_tenant - enables admin access across all tenants

    belongs_to :organisation, class_name: 'Admin::Organisation'
    has_many :project_permissions, class_name: 'Admin::ProjectPermission', dependent: :destroy
    has_many :users_with_access, through: :project_permissions, source: :user, class_name: 'Admin::User'

    scope :ordered_by_name, -> { order(:name) }
    scope :ordered_by_organisation, -> { joins(:organisation).order('organisations.name, projects.name') }
    scope :ordered_by_creation, -> { order(:created_at) }
    scope :with_description, -> { where.not(description: [nil, '']) }
    scope :with_repository, -> { where.not(repository: [nil, '']) }

    def organisation_name
      organisation&.name
    end

    def display_name
      name.presence || "Projekt #{id[0..7]}"
    end

    def short_description
      return 'Keine Beschreibung' if description.blank?

      description.truncate(SHORT_DESCRIPTION_LIMIT)
    end

    def repository_info
      return 'Kein Repository' if repository.blank?

      REPOSITORY_PROVIDERS.each do |domain, provider|
        return provider if repository.include?(domain)
      end

      'Externes Repository'
    end

    def total_users_with_access_count
      project_permissions.distinct.count(:user_id)
    end

    def users_with_read_access_count
      permission_user_ids = permissions_with_any_access.distinct.pluck(:user_id)
      time_session_user_ids = time_session_permissions_with_view_access.distinct.pluck(:user_id)

      (permission_user_ids | time_session_user_ids).count
    end

    def users_with_write_access_count
      permission_user_ids = permissions_with_write_access.distinct.pluck(:user_id)
      time_session_user_ids = time_session_permissions_with_write_access.distinct.pluck(:user_id)

      (permission_user_ids | time_session_user_ids).count
    end

    def project_permissions_with_details
      project_permissions.includes(:user).joins(:user).order('users.email')
    end

    def has_users_with_tickets_access?
      project_permissions.where.not(tickets_access: :no_access).exists?
    end

    def has_users_with_notes_access?
      project_permissions.where.not(notes_access: :no_access).exists?
    end

    def has_users_with_documents_access?
      project_permissions.where.not(documents_access: :no_access).exists?
    end

    def has_users_with_meetings_access?
      project_permissions.where.not(meetings_access: :no_access).exists?
    end

    def access_summary
      {
        total_users: total_users_with_access_count,
        read_access_users: users_with_read_access_count,
        write_access_users: users_with_write_access_count,
        tickets_access: has_users_with_tickets_access?,
        notes_access: has_users_with_notes_access?,
        documents_access: has_users_with_documents_access?,
        meetings_access: has_users_with_meetings_access?
      }
    end

    def status_css_class
      if total_users_with_access_count.positive?
        'bg-green-100 text-green-800'
      else
        'bg-gray-100 text-gray-800'
      end
    end

    def repository_css_class
      repository.present? ? 'bg-blue-100 text-blue-800' : 'bg-gray-100 text-gray-800'
    end

    private

    def permissions_with_any_access
      access_levels = %i[read_only read_write]

      project_permissions.where(tickets_access: access_levels)
                         .or(project_permissions.where(notes_access: access_levels))
                         .or(project_permissions.where(chats_access: access_levels))
                         .or(project_permissions.where(documents_access: access_levels))
                         .or(project_permissions.where(documentation_access: access_levels))
                         .or(project_permissions.where(meetings_access: access_levels))
    end

    def permissions_with_write_access
      project_permissions.where(tickets_access: :read_write)
                         .or(project_permissions.where(notes_access: :read_write))
                         .or(project_permissions.where(chats_access: :read_write))
                         .or(project_permissions.where(documents_access: :read_write))
                         .or(project_permissions.where(documentation_access: :read_write))
                         .or(project_permissions.where(meetings_access: :read_write))
    end

    def time_session_permissions_with_view_access
      time_session_rows_with(:can_view_own, :can_view_all)
    end

    def time_session_permissions_with_write_access
      time_session_rows_with(:can_create_own, :can_edit_own, :can_edit_all)
    end

    # Rows with any of these flags set, and only rows that still count
    # (TimeSessionPermission.backed_by_project_access).
    def time_session_rows_with(*flags)
      rows = TimeSessionPermission.backed_by_project_access.where(project_id: id)
      flags.map { |flag| rows.where(flag => true) }.reduce(:or)
    end
  end
end
