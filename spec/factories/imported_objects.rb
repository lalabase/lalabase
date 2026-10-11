# frozen_string_literal: true

# == Schema Information
#
# Table name: imported_objects
#
#  id                :uuid             not null, primary key
#  import_source     :string           not null
#  importable_type   :string           not null
#  imported_at       :datetime         not null
#  metadata          :json
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  import_session_id :string           not null
#  importable_id     :uuid             not null
#  organisation_id   :uuid             not null
#
# Indexes
#
#  idx_on_organisation_id_import_session_id_2f43c61367            (organisation_id,import_session_id)
#  index_imported_objects_on_import_session_id_and_import_source  (import_session_id,import_source)
#  index_imported_objects_on_importable                           (importable_type,importable_id)
#  index_imported_objects_on_imported_at                          (imported_at)
#  index_imported_objects_on_organisation_id                      (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#
FactoryBot.define do
  factory :imported_object do
    organisation
    association :importable, factory: :ticket
    import_session_id { SecureRandom.uuid }
    import_source { 'codebase_hq' }
    imported_at { Time.current }
    metadata { { original_id: '123', import_file_id: SecureRandom.uuid } }

    trait :with_ticket do
      association :importable, factory: :ticket
    end

    trait :with_post do
      association :importable, factory: :post
    end
  end
end
