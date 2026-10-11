# frozen_string_literal: true

module Projects
  class DefaultSmartFolderService
    include SmartFolders::Operators

    class NoSystemUserError < StandardError; end

    CUSTOM_PRIORITY_FIELD = 'custom_priority'
    PUBLIC_ACCESS_LEVEL = 1
    PRIVATE_ACCESS_LEVEL = 0
    DEFAULT_DAYS_WINDOW = '7'

    attr_reader :project

    def initialize(project)
      @project = project
    end

    # Called on project creation: creates all 5 folders
    def call(user)
      create_my_tasks(user)
      create_high_priority
      create_recently_created
      create_recently_updated
      create_unbilled
    end

    # Called when a user joins: only "Meine Aufgaben"
    def create_my_tasks_for(user)
      create_my_tasks(user)
    end

    private

    def create_my_tasks(user)
      return if project.smart_folders.exists?(user: user, name: folder_name(:my_tasks))

      ActiveRecord::Base.transaction do
        folder = build_folder(folder_name(:my_tasks), user, is_public: false)
        group = folder.smart_folder_rule_groups.create!(position: 1)
        SmartFolderRuleFactory.build(group, 'assignee', EQUALS, user.id.to_s, 1).save!
      end
    end

    def create_high_priority
      return if public_folder_exists?(:high_priority)
      return unless custom_priority_available?

      ActiveRecord::Base.transaction do
        folder = build_folder(folder_name(:high_priority), system_user!, is_public: true)
        group1 = folder.smart_folder_rule_groups.create!(position: 1)
        SmartFolderRuleFactory.build(group1, CUSTOM_PRIORITY_FIELD, EQUALS, 'high', 1).save!

        group2 = folder.smart_folder_rule_groups.create!(position: 2)
        SmartFolderRuleFactory.build(group2, CUSTOM_PRIORITY_FIELD, EQUALS, 'urgent', 1).save!
      end
    end

    def create_recently_created
      return if public_folder_exists?(:recently_created)

      ActiveRecord::Base.transaction do
        folder = build_folder(folder_name(:recently_created), system_user!, is_public: true,
                                                                            sort_column: 'created_at', sort_direction: 'desc')
        group = folder.smart_folder_rule_groups.create!(position: 1)
        SmartFolderRuleFactory.build(group, 'created_at', IN_THE_LAST_DAYS, DEFAULT_DAYS_WINDOW, 1).save!
      end
    end

    def create_recently_updated
      return if public_folder_exists?(:recently_updated)

      ActiveRecord::Base.transaction do
        folder = build_folder(folder_name(:recently_updated), system_user!, is_public: true,
                                                                            sort_column: 'updated_at', sort_direction: 'desc')
        group = folder.smart_folder_rule_groups.create!(position: 1)
        SmartFolderRuleFactory.build(group, 'updated_at', IN_THE_LAST_DAYS, DEFAULT_DAYS_WINDOW, 1).save!
      end
    end

    def create_unbilled
      return if public_folder_exists?(:unbilled)

      ActiveRecord::Base.transaction do
        folder = build_folder(folder_name(:unbilled), system_user!, is_public: true)
        group = folder.smart_folder_rule_groups.create!(position: 1)
        SmartFolderRuleFactory.build(group, 'has_time_sessions', IS, 'true', 1).save!
        SmartFolderRuleFactory.build(group, 'time_session_billed', IS_NOT, 'true', 2).save!
      end
    end

    def build_folder(name, user, is_public: false, sort_column: nil, sort_direction: nil)
      project.smart_folders.create!(
        name: name,
        user: user,
        organisation: project.organisation,
        target_object_type: 'Ticket',
        is_public: is_public,
        public_access_level: is_public ? PUBLIC_ACCESS_LEVEL : PRIVATE_ACCESS_LEVEL,
        sort_column: sort_column,
        sort_direction: sort_direction
      )
    end

    def public_folder_exists?(key)
      project.smart_folders.where(is_public: true).exists?(name: folder_name(key))
    end

    def system_user!
      @system_user ||= project.project_permissions.order(:created_at).first&.user ||
                       project.organisation.users.first

      raise NoSystemUserError, "No system user found for project #{project.id}" unless @system_user

      @system_user
    end

    def custom_priority_available?
      field_config = SmartFolderRule.field_config_with_custom_attributes(project.organisation, project)
      field_config.key?(CUSTOM_PRIORITY_FIELD)
    end

    def folder_name(key)
      I18n.t("services.default_smart_folder.#{key}")
    end
  end
end
