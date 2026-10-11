# frozen_string_literal: true

# == Schema Information
#
# Table name: notes
#
#  id                       :uuid             not null, primary key
#  create_embeddings        :boolean          default(TRUE)
#  description              :text
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  lock_version             :integer          default(0), not null
#  markdown_body            :text
#  plain_text_version       :text
#  plain_text_word_count    :integer
#  title                    :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  creator_id               :uuid             not null
#  organisation_id          :uuid             not null
#  project_id               :uuid             not null
#
# Indexes
#
#  index_notes_on_creator_id       (creator_id)
#  index_notes_on_organisation_id  (organisation_id)
#  index_notes_on_project_id       (project_id)
#
# Foreign Keys
#
#  fk_rails_...  (creator_id => users.id)
#
FactoryBot.define do
  factory :note do
    sequence(:title) { |n| "Test Note #{n}" }
    content { 'Test Content' }
    description { 'Test Description' }
    create_embeddings { true }
    association :project
    association :organisation
    association :creator, factory: :user
  end
end
