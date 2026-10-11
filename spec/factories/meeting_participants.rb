# frozen_string_literal: true

# Tenant note: create these inside ActsAsTenant.with_tenant(org) and pass a
# meeting from the SAME org — acts_as_tenant fills organisation_id from the
# current tenant, and the meeting/participant orgs must match.
# == Schema Information
#
# Table name: meeting_participants
#
#  id              :uuid             not null, primary key
#  display_name    :string           not null
#  normalized_name :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  meeting_id      :uuid             not null
#  organisation_id :uuid             not null
#  user_id         :uuid
#
# Indexes
#
#  idx_on_organisation_id_normalized_name_5eadc4a5e5             (organisation_id,normalized_name)
#  index_meeting_participants_on_meeting_id_and_normalized_name  (meeting_id,normalized_name) UNIQUE
#  index_meeting_participants_on_meeting_id_and_user_id          (meeting_id,user_id) UNIQUE WHERE (user_id IS NOT NULL)
#  index_meeting_participants_on_user_id                         (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (meeting_id => meetings.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#
FactoryBot.define do
  factory :meeting_participant do
    association :meeting
    display_name { 'Anna Ananas' }
    user { nil }
  end
end
