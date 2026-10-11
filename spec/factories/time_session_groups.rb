# frozen_string_literal: true

# == Schema Information
#
# Table name: time_session_groups
#
#  id              :uuid             not null, primary key
#  billed          :boolean          default(FALSE), not null
#  billed_at       :datetime
#  description     :text
#  invoice_number  :string
#  name            :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  creator_id      :uuid             not null
#  organisation_id :uuid             not null
#
# Indexes
#
#  index_time_session_groups_on_creator_id                     (creator_id)
#  index_time_session_groups_on_org_and_invoice_number_unique  (organisation_id,invoice_number) UNIQUE WHERE (invoice_number IS NOT NULL)
#  index_time_session_groups_on_organisation_id                (organisation_id)
#  index_time_session_groups_on_organisation_id_and_billed     (organisation_id,billed)
#
# Foreign Keys
#
#  fk_rails_...  (creator_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
FactoryBot.define do
  factory :time_session_group do
    name { "Time Session Group #{Faker::Number.unique.number(digits: 3)}" }
    description { 'Description for time session group' }
    billed { false }
    organisation
    creator { association :user, organisation: organisation }

    trait :billed do
      billed { true }
      invoice_number { "INV-#{Date.current.year}-#{Faker::Number.unique.number(digits: 4)}" }
      billed_at { 1.week.ago }
    end

    trait :with_time_sessions do
      after(:create) do |group|
        project = create(:project, organisation: group.organisation)
        create_list(:time_session, 3,
                    time_session_group: group,
                    project: project,
                    organisation: group.organisation)
      end
    end
  end
end
