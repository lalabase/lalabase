# frozen_string_literal: true

# == Schema Information
#
# Table name: time_sessions
#
#  id                    :uuid             not null, primary key
#  billed                :boolean          default(FALSE), not null
#  billed_at             :datetime
#  customer_description  :text
#  deleted_at            :datetime
#  description           :text
#  duration              :integer          not null
#  invoice_number        :string
#  occurred_on           :datetime         not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  creator_id            :uuid             not null
#  meeting_id            :uuid
#  organisation_id       :uuid             not null
#  project_id            :uuid             not null
#  ticket_id             :uuid
#  time_session_group_id :uuid
#
# Indexes
#
#  index_time_sessions_active_project_occurred        (deleted_at,project_id,occurred_on)
#  index_time_sessions_on_billed                      (billed)
#  index_time_sessions_on_creator_id                  (creator_id)
#  index_time_sessions_on_creator_id_and_occurred_on  (creator_id,occurred_on)
#  index_time_sessions_on_customer_description        (customer_description) WHERE (customer_description IS NOT NULL)
#  index_time_sessions_on_deleted_at                  (deleted_at)
#  index_time_sessions_on_meeting_id                  (meeting_id)
#  index_time_sessions_on_organisation_id             (organisation_id)
#  index_time_sessions_on_project_billed              (project_id,billed_at)
#  index_time_sessions_on_project_id                  (project_id)
#  index_time_sessions_on_project_occurred            (project_id,occurred_on)
#  index_time_sessions_on_ticket_id                   (ticket_id)
#  index_time_sessions_on_ticket_occurred             (ticket_id,occurred_on)
#  index_time_sessions_on_time_session_group_id       (time_session_group_id)
#
# Foreign Keys
#
#  fk_rails_...  (creator_id => users.id)
#  fk_rails_...  (meeting_id => meetings.id) ON DELETE => nullify
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (ticket_id => tickets.id)
#  fk_rails_...  (time_session_group_id => time_session_groups.id)
#
FactoryBot.define do
  factory :time_session do
    association :project
    association :creator, factory: :user
    association :organisation
    sequence(:occurred_on) { |n| Time.current + n.hours }
    duration { 60 }
    description { 'Test time session' }

    before(:create) do |time_session|
      create(:membership, user: time_session.creator, organisation: time_session.project.organisation) unless time_session.creator.organisations.include?(time_session.project.organisation)
    end
  end
end
