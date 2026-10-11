# frozen_string_literal: true

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
# spec/factories/projects.rb

FactoryBot.define do
  factory :project do
    name { Faker::Alphanumeric.alpha(number: 10) }
    description { 'Test Description' }
    repository { 'https://github.com/test/project' }
    association :organisation
  end
end
