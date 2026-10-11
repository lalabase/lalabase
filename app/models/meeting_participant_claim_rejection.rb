# frozen_string_literal: true

# Nachtrag (Teilnehmer-Claim): a persisted "no, this external name is NOT this
# member" decision made by a Meetings-writer. It suppresses the live claim hint
# for a given (org member, normalized_name) pair so real name doppelgängers stop
# nagging. Tenant-scoped; the user FK cascades (a rejection without its member is
# meaningless — see the migration). normalized_name uses the same key as
# MeetingParticipant.normalize_name, so it lines up with the external rows it hides.
# == Schema Information
#
# Table name: meeting_participant_claim_rejections
#
#  id              :uuid             not null, primary key
#  normalized_name :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  user_id         :uuid             not null
#
# Indexes
#
#  idx_mp_claim_rejections_org_user_name                  (organisation_id,user_id,normalized_name) UNIQUE
#  index_meeting_participant_claim_rejections_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class MeetingParticipantClaimRejection < ApplicationRecord
  acts_as_tenant(:organisation)

  belongs_to :user

  validates :normalized_name, presence: true
  # The DB unique index is the real idempotency guard (reject uses find_or_create_by);
  # this validation just surfaces a clean error when rows are built directly.
  validates :normalized_name, uniqueness: { scope: %i[organisation_id user_id] }, allow_blank: true
end
