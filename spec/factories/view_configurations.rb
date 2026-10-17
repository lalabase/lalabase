# frozen_string_literal: true

# == Schema Information
#
# Table name: view_configurations
#
#  id                             :uuid             not null, primary key
#  detail_settings                :jsonb
#  header_columns                 :jsonb
#  list_columns                   :jsonb
#  pinned_columns                 :jsonb
#  table_columns                  :jsonb
#  view_mode                      :string           default("table")
#  view_type                      :string           default("tickets")
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#  kanban_attribute_definition_id :uuid
#  organisation_id                :uuid             not null
#  project_id                     :uuid
#  user_id                        :uuid             not null
#
# Indexes
#
#  index_view_configs_on_user_organisation_type_without_project  (user_id,organisation_id,view_type) UNIQUE WHERE (project_id IS NULL)
#  index_view_configs_on_user_project_type                       (user_id,project_id,view_type) UNIQUE
#  index_view_configurations_on_header_columns                   (header_columns) USING gin
#  index_view_configurations_on_list_columns                     (list_columns) USING gin
#  index_view_configurations_on_organisation_id                  (organisation_id)
#  index_view_configurations_on_project_id                       (project_id)
#  index_view_configurations_on_table_columns                    (table_columns) USING gin
#  index_view_configurations_on_user_id                          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (kanban_attribute_definition_id => ticket_attribute_definitions.id) ON DELETE => nullify
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  factory :view_configuration do
    association :user
    association :project
    association :organisation
    view_type { 'tickets' }
    view_mode { 'table' }
    table_columns { ViewConfiguration::DEFAULT_TABLE_COLUMNS }
    header_columns { ViewConfiguration::DEFAULT_HEADER_COLUMNS }
  end
end
