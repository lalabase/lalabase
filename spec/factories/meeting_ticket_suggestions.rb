# frozen_string_literal: true

# == Schema Information
#
# Table name: meeting_ticket_suggestions
#
#  id                :uuid             not null, primary key
#  description       :text             default(""), not null
#  status            :integer          default(0), not null
#  title             :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  created_ticket_id :uuid
#  meeting_id        :uuid             not null
#  organisation_id   :uuid             not null
#  similar_ticket_id :uuid
#
FactoryBot.define do
  factory :meeting_ticket_suggestion do
    association :meeting
    # Keep org consistent with the meeting by default (tenant-aware factory).
    organisation { meeting.organisation }
    sequence(:title) { |n| "Rückruf bei Kunde X (#{n})" }
    description { 'Der Kunde wartet auf eine Rückmeldung zum Angebot.' }
    status { :open }

    trait :accepted do
      status { :accepted }
    end

    trait :dismissed do
      status { :dismissed }
    end
  end
end
