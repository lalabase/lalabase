# frozen_string_literal: true

# == Schema Information
#
# Table name: user_data_exports
#
#  id            :uuid             not null, primary key
#  completed_at  :datetime
#  error_message :string
#  expires_at    :datetime
#  status        :string           default("pending"), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  user_id       :uuid             not null
#
# Indexes
#
#  idx_user_data_exports_one_active_per_user          (user_id) UNIQUE WHERE ((status)::text = ANY ((ARRAY['pending'::character varying, 'processing'::character varying])::text[]))
#  index_user_data_exports_on_user_id                 (user_id)
#  index_user_data_exports_on_user_id_and_created_at  (user_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
FactoryBot.define do
  factory :user_data_export do
    association :user
    status { 'pending' }

    trait :processing do
      status { 'processing' }
    end

    trait :completed do
      status { 'completed' }
      completed_at { Time.current }
      expires_at { UserDataExport::RETENTION.from_now }

      after(:build) do |export|
        export.archive.attach(
          io: StringIO.new("PK\x03\x04 test zip"),
          filename: 'lalabase-datenauskunft.zip',
          content_type: 'application/zip'
        )
      end
    end

    trait :expired do
      completed
      created_at { 9.days.ago }
      completed_at { 8.days.ago }
      expires_at { 1.day.ago }
    end

    trait :failed do
      status { 'failed' }
      error_message { 'export_failed' }
    end
  end
end
