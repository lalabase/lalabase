# frozen_string_literal: true

# == Schema Information
#
# Table name: activities
#
#  id                :uuid             not null, primary key
#  action            :string           not null
#  attribute_changes :jsonb
#  key               :string           not null
#  parameters        :jsonb
#  secondary_type    :string
#  trackable_type    :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  actor_id          :uuid             not null
#  organisation_id   :uuid             not null
#  secondary_id      :uuid
#  trackable_id      :uuid             not null
#
# Indexes
#
#  index_activities_on_actor_and_time       (actor_id,created_at)
#  index_activities_on_actor_id             (actor_id)
#  index_activities_on_org_action_and_time  (organisation_id,action,created_at)
#  index_activities_on_org_key_and_time     (organisation_id,key,created_at)
#  index_activities_on_organisation_id      (organisation_id)
#  index_activities_on_secondary            (secondary_type,secondary_id)
#  index_activities_on_secondary_ref        (secondary_type,secondary_id)
#  index_activities_on_trackable            (trackable_type,trackable_id)
#  index_activities_on_trackable_and_time   (trackable_type,trackable_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (actor_id => users.id)
#  fk_rails_...  (organisation_id => organisations.id)
#
FactoryBot.define do
  factory :activity do
    to_create do |instance|
      # Allow creating non-persisted instances when DB constraints would fail (e.g., actor nil)
      instance.save(validate: false) unless instance.actor.nil?
    end
    association :actor, factory: :user
    association :organisation
    association :trackable, factory: :ticket
    action { 'created' }
    key { 'ticket.created' }
    parameters { {} }
    attribute_changes { {} }

    trait :with_secondary do
      association :secondary, factory: :post
    end

    trait :updated do
      action { 'updated' }
      key { 'ticket.updated' }
      attribute_changes { { 'title' => ['Old Title', 'New Title'] } }
    end

    trait :status_changed do
      action { 'status_changed' }
      key { 'ticket.status_changed' }
      parameters { { 'from_status' => 'Open', 'to_status' => 'Closed' } }
      attribute_changes { { 'status_name' => %w[Open Closed] } }
    end

    trait :assigned do
      action { 'assigned' }
      key { 'ticket.assigned' }
      association :secondary, factory: :user
      parameters { { 'user_role' => 'Mitglied' } }
    end

    trait :post_added do
      action { 'post_added' }
      key { 'ticket.post_added' }
      association :secondary, factory: :post
      parameters { { 'post_preview' => 'This is a comment...' } }
    end
  end
end
