# frozen_string_literal: true

require 'rails_helper'

# MeetingParticipantClaimRejection — the "no, this external name is NOT this member"
# record that suppresses the claim hint. Intent per describe:
#  - validations: a rejection needs a normalized_name; the (org, user, name) triple
#    is unique so re-rejecting cannot duplicate.
#  - tenant isolation: acts_as_tenant must never surface a sibling org's rejection.
#  - user cascade: the FK is on_delete: :cascade — deleting the member row must take
#    its rejections with it (without the member the rejection is meaningless).
RSpec.describe MeetingParticipantClaimRejection do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  # A tenant must be set before building an acts_as_tenant record (require_tenant).
  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  it 'is valid with an org (via tenant), a user and a normalized name' do
    expect(described_class.new(user: user, normalized_name: 'karl krause')).to be_valid
  end

  it 'requires a normalized_name' do
    expect(described_class.new(user: user, normalized_name: '')).not_to be_valid
  end

  it 'stamps the organisation from the current tenant' do
    rejection = described_class.create!(user: user, normalized_name: 'karl krause')
    expect(rejection.organisation).to eq(organisation)
  end

  describe 'uniqueness per (organisation, user, normalized_name)' do
    before { described_class.create!(user: user, normalized_name: 'karl krause') }

    it 'rejects a duplicate for the same member and name' do
      expect(described_class.new(user: user, normalized_name: 'karl krause')).not_to be_valid
    end

    it 'allows the SAME name for a DIFFERENT member (real doppelgänger case)' do
      expect(described_class.new(user: create(:user), normalized_name: 'karl krause')).to be_valid
    end

    it 'allows a DIFFERENT name for the same member' do
      expect(described_class.new(user: user, normalized_name: 'anna ananas')).to be_valid
    end
  end

  describe 'tenant isolation (acts_as_tenant)' do
    it 'never surfaces a rejection from another organisation' do
      described_class.create!(user: user, normalized_name: 'karl krause')

      ActsAsTenant.with_tenant(create(:organisation)) do
        expect(described_class.count).to eq(0)
      end
    end
  end

  describe 'user cascade (FK on_delete: :cascade)' do
    it 'is removed at the DB level when its user row is deleted' do
      bare_user = create(:user)
      rejection = described_class.create!(user: bare_user, normalized_name: 'karl krause')

      # Raw DELETE (not the app's soft-delete flow) to exercise the FK cascade itself.
      User.where(id: bare_user.id).delete_all

      expect(described_class.where(id: rejection.id)).to be_empty
    end
  end
end
