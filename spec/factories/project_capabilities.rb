# frozen_string_literal: true

# == Schema Information
#
# Table name: project_capabilities
#
#  id                :uuid             not null, primary key
#  auto_generated    :boolean          default(TRUE), not null
#  description       :text             not null
#  key_modules       :jsonb            not null
#  name              :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  edited_by_user_id :uuid
#  organisation_id   :uuid             not null
#  project_id        :uuid             not null
#
# Indexes
#
#  index_project_capabilities_on_edited_by_user_id    (edited_by_user_id)
#  index_project_capabilities_on_organisation_id      (organisation_id)
#  index_project_capabilities_on_project_id           (project_id)
#  index_project_capabilities_on_project_id_and_name  (project_id,name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (edited_by_user_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#
FactoryBot.define do
  factory :project_capability do
    project
    organisation { project.organisation }
    sequence(:name) { |n| "Capability #{n}" }
    description { 'Handles notifications across in-app, email, and webhook channels.' }
    key_modules { [] }
    auto_generated { true }
  end
end
