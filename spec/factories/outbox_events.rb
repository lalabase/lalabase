# frozen_string_literal: true

# == Schema Information
#
# Table name: outbox_events
#
#  id              :uuid             not null, primary key
#  available_at    :datetime         not null
#  error_message   :string
#  event_type      :string           not null
#  payload         :jsonb            not null
#  processed_at    :datetime
#  retry_count     :integer          default(0)
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  activity_id     :uuid             not null
#  organisation_id :uuid             not null
#
# Indexes
#
#  idx_outbox_processing                   (available_at,processed_at)
#  index_outbox_events_on_activity_id      (activity_id)
#  index_outbox_events_on_organisation_id  (organisation_id)
#
# Foreign Keys
#
#  fk_rails_...  (activity_id => activities.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
FactoryBot.define do
  factory :outbox_event do
    association :organisation
    association :activity
    event_type { 'ticket_commented' }
    payload { { test: 'data' } }
    available_at { Time.current }
    processed_at { nil }
    retry_count { 0 }
  end
end
