# frozen_string_literal: true

# == Schema Information
#
# Table name: project_layer4_visions
#
#  id                :uuid             not null, primary key
#  auto_generated    :boolean          default(TRUE), not null
#  content           :text             not null
#  language          :string           default("en"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  edited_by_user_id :uuid
#  organisation_id   :uuid             not null
#  project_id        :uuid             not null
#
# Indexes
#
#  index_project_layer4_visions_on_edited_by_user_id  (edited_by_user_id)
#  index_project_layer4_visions_on_organisation_id    (organisation_id)
#  index_project_layer4_visions_on_project_id         (project_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (edited_by_user_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#
FactoryBot.define do
  factory :project_layer4_vision do
    project
    organisation { project.organisation }
    content { 'Lalabase is a multi-tenant ticketing platform with AI-assisted requirements clarification.' }
    auto_generated { true }
    language { 'en' }
  end
end
