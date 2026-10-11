# frozen_string_literal: true

# == Schema Information
#
# Table name: document_versions
#
#  id                       :uuid             not null, primary key
#  create_embeddings        :boolean          default(TRUE)
#  create_summary           :boolean          default(FALSE)
#  description              :text
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  generated_summary        :text             default("")
#  number                   :integer
#  plain_text_version       :text
#  plain_text_word_count    :integer
#  summary_creation_error   :text             default("")
#  summary_creation_flag    :boolean          default(FALSE)
#  title                    :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  document_id              :uuid             not null
#  organisation_id          :uuid             not null
#  user_id                  :uuid
#
# Indexes
#
#  index_document_versions_on_document_id      (document_id)
#  index_document_versions_on_organisation_id  (organisation_id)
#  index_document_versions_on_user_id          (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#

FactoryBot.define do
  factory :document_version do
    title { 'Version 1' }
    description { 'Initial version' }
    create_embeddings { true }
    association :document
    association :organisation
    document_version_file do
      Rack::Test::UploadedFile.new(
        StringIO.new('dummy content'),
        'text/plain',
        true,
        original_filename: 'test.txt'
      )
    end
  end
end
