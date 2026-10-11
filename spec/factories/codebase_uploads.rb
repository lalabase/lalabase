# frozen_string_literal: true

# == Schema Information
#
# Table name: codebase_uploads
#
#  id                 :uuid             not null, primary key
#  file_name          :string           not null
#  file_path          :string
#  linked_object_type :string           not null
#  processed          :boolean          default(FALSE)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  codebase_upload_id :string           not null
#  import_session_id  :string           not null
#  linked_object_id   :string           not null
#  organisation_id    :uuid             not null
#
# Indexes
#
#  idx_on_codebase_upload_id_organisation_id_d46c273408   (codebase_upload_id,organisation_id)
#  idx_on_linked_object_type_linked_object_id_88d5bd8833  (linked_object_type,linked_object_id)
#  index_codebase_uploads_on_import_session_id            (import_session_id)
#  index_codebase_uploads_on_organisation_id              (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
FactoryBot.define do
  factory :codebase_upload do
    association :organisation

    sequence(:codebase_upload_id) { |n| "upload_#{n}" }
    file_name { 'attachment.pdf' }
    linked_object_type { CodebaseUpload::LINKED_TYPE_TICKET_UPDATE }
    sequence(:linked_object_id) { |n| "update_#{n}" }
    import_session_id { "test_session_#{SecureRandom.hex(4)}" }
    processed { false }

    trait :processed do
      processed { true }
    end

    trait :ticket_upload do
      linked_object_type { CodebaseUpload::LINKED_TYPE_TICKET_UPDATE }
    end

    trait :project_file do
      linked_object_type { CodebaseUpload::LINKED_TYPE_PROJECT_FILE }
    end

    trait :account_file do
      linked_object_type { CodebaseUpload::LINKED_TYPE_ACCOUNT }
    end
  end
end
