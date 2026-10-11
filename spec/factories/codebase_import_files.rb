# frozen_string_literal: true

# == Schema Information
#
# Table name: codebase_import_files
#
#  id                      :uuid             not null, primary key
#  error_message           :text
#  file_content            :text
#  file_size               :integer
#  file_type               :string           not null
#  import_summary          :json
#  metadata                :json
#  original_filename       :string
#  processed_at            :datetime
#  processing_completed_at :datetime
#  processing_started_at   :datetime
#  status                  :string           default("uploaded")
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  organisation_id         :uuid             not null
#  project_id              :uuid
#  user_id                 :uuid             not null
#
# Indexes
#
#  index_codebase_import_files_on_organisation_id                 (organisation_id)
#  index_codebase_import_files_on_organisation_id_and_file_type   (organisation_id,file_type)
#  index_codebase_import_files_on_organisation_id_and_project_id  (organisation_id,project_id)
#  index_codebase_import_files_on_project_id                      (project_id)
#  index_codebase_import_files_on_status                          (status)
#  index_codebase_import_files_on_user_id                         (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
FactoryBot.define do
  factory :codebase_import_file do
    association :organisation
    association :user
    project { nil }

    file_type { 'tickets' }
    original_filename { 'test_tickets.xml' }
    file_content { '<tickets></tickets>' }
    file_size { 1024 }
    status { 'uploaded' }

    trait :with_tickets_data do
      file_content do
        <<~XML
          <tickets>
            <tickets-ticket>
              <id>123</id>
              <number>1</number>
              <subject>Test Ticket</subject>
              <description>Test Description</description>
              <status-cache>Open</status-cache>
              <priority-cache>High</priority-cache>
              <created-at>2023-01-01T10:00:00Z</created-at>
              <updated-at>2023-01-01T11:00:00Z</updated-at>
            </tickets-ticket>
          </tickets>
        XML
      end
    end

    trait :users_file do
      file_type { 'users' }
      original_filename { 'test_users.xml' }
      file_content { '<users></users>' }
    end

    trait :with_valid_users_xml do
      file_type { 'users' }
      original_filename { 'test_users.xml' }
      file_content do
        <<~XML
          <users-users>
            <users-user>
              <id>1</id>
              <first-name>Test</first-name>
              <last-name>User</last-name>
              <email-address>test@example.com</email-address>
              <company>TestCo</company>
            </users-user>
          </users-users>
        XML
      end
    end

    trait :with_valid_tickets_xml do
      file_type { 'tickets' }
      original_filename { 'test_tickets.xml' }
      file_content do
        <<~XML
          <tickets-tickets>
            <tickets-ticket>
              <id>123</id>
              <ticket-id>1</ticket-id>
              <subject>Test Ticket</subject>
              <ticket-type>Task</ticket-type>
              <reporter-id>1</reporter-id>
              <assignee-id>2</assignee-id>
              <status-cache>Open</status-cache>
              <priority-cache>High</priority-cache>
              <project-id>10</project-id>
              <created-at>2023-01-01T10:00:00Z</created-at>
              <updated-at>2023-01-01T11:00:00Z</updated-at>
              <updates></updates>
            </tickets-ticket>
          </tickets-tickets>
        XML
      end
    end

    trait :time_tracking_file do
      file_type { 'time_tracking' }
      original_filename { 'test_time_tracking.xml' }
      file_content { '<time-sessions></time-sessions>' }
    end

    trait :with_valid_time_tracking_xml do
      file_type { 'time_tracking' }
      original_filename { 'test_time_tracking.xml' }
      file_content do
        <<~XML
          <time-sessions-sessions>
            <time-sessions-session>
              <id>1</id>
              <minutes>60</minutes>
              <summary>Test session</summary>
              <user-id>1</user-id>
              <project-id>10</project-id>
              <occurred-on>2023-01-15</occurred-on>
            </time-sessions-session>
          </time-sessions-sessions>
        XML
      end
    end

    trait :uploads_file do
      file_type { 'uploads' }
      original_filename { 'test_uploads.xml' }
      file_content { '<uploads></uploads>' }
    end

    trait :processing do
      status { 'processing' }
      processing_started_at { 5.minutes.ago }
    end

    trait :processed do
      status { 'processed' }
      processing_started_at { 1.hour.ago }
      processing_completed_at { 30.minutes.ago }
    end

    trait :failed do
      status { 'failed' }
      processing_started_at { 1.hour.ago }
      processing_completed_at { 30.minutes.ago }
      error_message { 'Processing failed' }
    end

    trait :with_project do
      association :project
    end
  end
end
