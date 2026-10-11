# frozen_string_literal: true

# == Schema Information
#
# Table name: post_documents
#
#  id                       :uuid             not null, primary key
#  create_embeddings        :boolean          default(TRUE)
#  embedding_creation_error :text
#  embeddings_creation_flag :boolean
#  plain_text_version       :text
#  plain_text_word_count    :integer
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  organisation_id          :uuid             not null
#  post_id                  :uuid             not null
#
# Indexes
#
#  index_post_documents_on_organisation_id  (organisation_id)
#
FactoryBot.define do
  factory :post_document do
    association :post
    association :organisation
    create_embeddings { true }

    after(:build) do |post_document|
      post_document.post_document_file.attach(
        io: StringIO.new('test file content'),
        filename: 'test_document.txt',
        content_type: 'text/plain'
      )
    end

    trait :without_embeddings do
      create_embeddings { false }
    end

    trait :with_pdf do
      after(:build) do |post_document|
        post_document.post_document_file.attach(
          io: StringIO.new('%PDF-1.4 fake pdf content'),
          filename: 'test_document.pdf',
          content_type: 'application/pdf'
        )
      end
    end

    trait :with_unsupported_file do
      after(:build) do |post_document|
        post_document.post_document_file.attach(
          io: StringIO.new('binary content'),
          filename: 'test_file.zip',
          content_type: 'application/zip'
        )
      end
    end
  end
end
