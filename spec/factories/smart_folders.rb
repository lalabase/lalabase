# frozen_string_literal: true

# == Schema Information
#
# Table name: smart_folders
#
#  id                  :uuid             not null, primary key
#  color_code          :integer
#  description         :text
#  display_columns     :jsonb
#  is_public           :boolean          default(FALSE)
#  name                :string           not null
#  position            :integer
#  public_access_level :integer          default(0)
#  sort_by             :integer          default(0)
#  sort_column         :string
#  sort_direction      :string
#  target_object_type  :string           default("Note")
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  organisation_id     :uuid             not null
#  project_id          :uuid
#  user_id             :uuid             not null
#
# Indexes
#
#  index_smart_folders_on_organisation_id                         (organisation_id)
#  index_smart_folders_on_organisation_id_and_is_public           (organisation_id,is_public)
#  index_smart_folders_on_organisation_id_and_project_id          (organisation_id,project_id)
#  index_smart_folders_on_organisation_id_and_target_object_type  (organisation_id,target_object_type)
#  index_smart_folders_on_organisation_id_and_user_id             (organisation_id,user_id)
#  index_smart_folders_on_project_id                              (project_id)
#  index_smart_folders_on_user_id                                 (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  factory :smart_folder do
    name { Faker::Lorem.words(number: 3).join(' ') }
    association :user
    association :organisation
    association :project
    target_object_type { 'Note' }
    is_public { false }
    public_access_level { 0 }
    sort_by { 0 }
    position { 1 }
    description { Faker::Lorem.sentence }
  end
end
