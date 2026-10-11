# frozen_string_literal: true

# == Schema Information
#
# Table name: meetings
#
#  id                     :uuid             not null, primary key
#  create_embeddings      :boolean          default(FALSE), not null
#  duration_minutes       :integer
#  generated_summary      :text             default(""), not null
#  notes                  :text
#  occurred_at            :datetime         not null
#  plain_text_version     :text
#  summary_creation_error :text             default(""), not null
#  summary_creation_flag  :boolean          default(FALSE), not null
#  title                  :string           not null
#  transcript             :text
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  creator_id             :uuid             not null
#  organisation_id        :uuid             not null
#  project_id             :uuid             not null
#
# Indexes
#
#  index_meetings_on_creator_id                  (creator_id)
#  index_meetings_on_organisation_id             (organisation_id)
#  index_meetings_on_project_id_and_occurred_at  (project_id,occurred_at)
#
# Foreign Keys
#
#  fk_rails_...  (creator_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#
FactoryBot.define do
  factory :meeting do
    sequence(:title) { |n| "Test Meeting #{n}" }
    occurred_at { Time.current }
    duration_minutes { nil }
    notes { nil }
    transcript { nil }
    create_embeddings { false }
    association :project
    association :organisation
    association :creator, factory: :user
  end
end
