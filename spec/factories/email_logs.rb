# frozen_string_literal: true

# == Schema Information
#
# Table name: email_logs
#
#  id                   :uuid             not null, primary key
#  body_html_compressed :binary
#  body_preview         :text
#  body_text            :text
#  bounce_type          :string
#  bounced_at           :datetime
#  can_retry            :boolean          default(TRUE)
#  click_count          :integer          default(0)
#  clicked_at           :datetime
#  delivered_at         :datetime
#  failed_at            :datetime
#  failure_reason       :text
#  lock_version         :integer          default(0), not null
#  metadata             :jsonb            not null
#  open_count           :integer          default(0)
#  opened_at            :datetime
#  recipient_email      :string
#  retry_count          :integer          default(0)
#  sent_at              :datetime
#  status               :integer          default("queued"), not null
#  subject              :string
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  notification_id      :uuid             not null
#  organisation_id      :uuid             not null
#  provider_message_id  :string
#  resent_from_id       :uuid
#
# Indexes
#
#  idx_email_logs_dashboard                         (organisation_id,status,created_at)
#  idx_email_logs_provider_msg                      (provider_message_id) WHERE (provider_message_id IS NOT NULL)
#  index_email_logs_on_notification_id_and_status   (notification_id,status)
#  index_email_logs_on_organisation_id_and_sent_at  (organisation_id,sent_at)
#  index_email_logs_on_organisation_id_and_status   (organisation_id,status)
#  index_email_logs_on_recipient_email              (recipient_email)
#  index_email_logs_on_resent_from_id               (resent_from_id)
#  index_email_logs_on_sent_at                      (sent_at)
#  index_email_logs_on_status_and_created_at        (status,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (notification_id => notifications.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (resent_from_id => email_logs.id)
#
FactoryBot.define do
  factory :email_log do
    association :organisation
    association :notification

    recipient_email { Faker::Internet.email }
    subject { "Test Email: #{Faker::Lorem.sentence}" }
    status { 'queued' }

    # Optional fields
    body_text { Faker::Lorem.paragraph }
    body_preview { Faker::Lorem.sentence }
    metadata { {} }
    lock_version { 0 }

    # Status-specific traits
    trait :sent do
      status { 'sent' }
      sent_at { 1.hour.ago }
      provider_message_id { SecureRandom.uuid }
    end

    trait :delivered do
      status { 'delivered' }
      sent_at { 2.hours.ago }
      delivered_at { 1.hour.ago }
      provider_message_id { SecureRandom.uuid }
    end

    trait :opened do
      status { 'opened' }
      sent_at { 3.hours.ago }
      delivered_at { 2.hours.ago }
      opened_at { 1.hour.ago }
      open_count { 1 }
      provider_message_id { SecureRandom.uuid }
    end

    trait :clicked do
      status { 'clicked' }
      sent_at { 4.hours.ago }
      delivered_at { 3.hours.ago }
      opened_at { 2.hours.ago }
      clicked_at { 1.hour.ago }
      open_count { 2 }
      click_count { 1 }
      provider_message_id { SecureRandom.uuid }
    end

    trait :bounced do
      status { 'bounced' }
      sent_at { 1.hour.ago }
      bounced_at { 30.minutes.ago }
      bounce_type { 'hard' }
      failure_reason { 'Mailbox does not exist' }
      provider_message_id { SecureRandom.uuid }
    end

    trait :failed do
      status { 'failed' }
      failure_reason { 'Connection timeout' }
    end

    trait :complaint do
      status { 'complaint' }
      sent_at { 1.day.ago }
      delivered_at { 23.hours.ago }
      metadata { { 'complaint_type' => 'spam' } }
      provider_message_id { SecureRandom.uuid }
    end

    trait :deferred do
      status { 'deferred' }
      sent_at { 1.hour.ago }
      failure_reason { 'Temporary failure - will retry' }
      provider_message_id { SecureRandom.uuid }
    end

    trait :with_html_content do
      after(:build) do |email_log|
        email_log.body_html = "<html><body><h1>Test Email</h1><p>#{Faker::Lorem.paragraph}</p></body></html>"
      end
    end

    trait :with_large_content do
      after(:build) do |email_log|
        email_log.body_html = "<html><body>#{'X' * 10_000}</body></html>"
        email_log.body_text = 'Y' * 10_000
      end
    end
  end
end
