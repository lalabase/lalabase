# frozen_string_literal: true

# Invitation#out_of_date? is the ONLY expiry gate for token registrations
# (users/registrations_controller — the previous code called a non-existent
# `expired?` and 500ed every brand-new user arriving via invitation link).
# These boundary specs pin the 3-day TTL against off-by-one mutations
# (`<` ↔ `<=`) and against silent renames of the method.
require 'rails_helper'

RSpec.describe Invitation, :ci_guard, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe '#out_of_date? (3-day TTL boundary)' do
    around { |example| freeze_time { example.run } }

    it 'is out of date one second past the 3-day mark (n+1)' do
      invitation = create(:invitation, organisation: organisation, sent_at: 3.days.ago - 1.second)
      expect(invitation.out_of_date?).to be(true)
    end

    it 'is NOT out of date exactly at the 3-day mark (n — strict <)' do
      invitation = create(:invitation, organisation: organisation, sent_at: 3.days.ago)
      expect(invitation.out_of_date?).to be(false)
    end

    it 'is NOT out of date one second before the 3-day mark (n-1)' do
      invitation = create(:invitation, organisation: organisation, sent_at: 3.days.ago + 1.second)
      expect(invitation.out_of_date?).to be(false)
    end

    # Conservative nil handling: a never-sent invitation has nothing proving
    # its freshness — and `nil < time` would crash the registration flow.
    it 'treats a missing sent_at as out of date instead of crashing' do
      invitation = build(:invitation, organisation: organisation, sent_at: nil)
      expect(invitation.out_of_date?).to be(true)
    end
  end

  # The token is the whole credential of an invitation link: whoever holds it
  # can accept. Its uniqueness is held twice, and each layer is pinned alone.
  describe 'token' do
    it 'is generated on create when none is given' do
      invitation = create(:invitation, organisation: organisation, token: nil)
      expect(invitation.token).to match(/\A\h{20}\z/)
    end

    it 'keeps an explicitly given token' do
      expect(create(:invitation, organisation: organisation, token: 'given-token').token).to eq('given-token')
    end

    it 'is not regenerated on update' do
      invitation = create(:invitation, organisation: organisation, token: nil)
      expect { invitation.update!(accepted_at: Time.current) }.not_to(change { invitation.reload.token })
    end

    it 'differs between invitations' do
      tokens = Array.new(2) { create(:invitation, organisation: organisation, token: nil).token }
      expect(tokens.uniq.size).to eq(2)
    end

    it 'is rejected by the model when already taken' do
      create(:invitation, organisation: organisation, token: 'taken')
      duplicate = build(:invitation, organisation: organisation, token: 'taken')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:token]).to be_present
    end

    # Across organisations too: the token alone finds the invitation (without a
    # tenant), so it must be globally unique, not per organisation.
    it 'is rejected by the model when taken in another organisation' do
      ActsAsTenant.with_tenant(create(:organisation)) { create(:invitation, token: 'taken') }
      ActsAsTenant.current_tenant = organisation

      expect(build(:invitation, organisation: organisation, token: 'taken')).not_to be_valid
    end

    it 'is rejected by the database when the model validation is bypassed' do
      create(:invitation, organisation: organisation, token: 'taken')
      racer = build(:invitation, organisation: organisation, token: 'taken')

      expect { racer.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'email' do
    it 'is required' do
      invitation = build(:invitation, organisation: organisation, email: '')
      expect(invitation).not_to be_valid
      expect(invitation.errors[:email]).to be_present
    end

    %w[plain-text two@@example.com].each do |bad|
      it "rejects #{bad.inspect}" do
        invitation = build(:invitation, organisation: organisation, email: bad)
        expect(invitation).not_to be_valid
        expect(invitation.errors[:email]).to be_present
      end
    end

    it 'accepts an ordinary address' do
      expect(build(:invitation, organisation: organisation, email: 'person@example.com')).to be_valid
    end
  end

  # The model declares the inviter optional, the schema does not
  # (inviter_id NOT NULL, no foreign key). Pinned so a change on either side
  # is a decision, not an accident.
  describe 'inviter' do
    it 'is not required by the model' do
      expect(build(:invitation, organisation: organisation, inviter: nil)).to be_valid
    end

    it 'is required by the database' do
      expect { create(:invitation, organisation: organisation, inviter: nil) }
        .to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe '.redeemable (SQL twin of out_of_date? and accepted?)' do
    around { |example| freeze_time { example.run } }

    def redeemable?(invitation)
      described_class.redeemable.exists?(invitation.id)
    end

    it 'excludes one second past the 3-day mark (n+1)' do
      invitation = create(:invitation, organisation: organisation, sent_at: 3.days.ago - 1.second)
      expect(redeemable?(invitation)).to be(false)
    end

    it 'includes exactly the 3-day mark, like out_of_date? (n)' do
      invitation = create(:invitation, organisation: organisation, sent_at: 3.days.ago)
      expect(redeemable?(invitation)).to be(true)
      expect(invitation.out_of_date?).to be(false)
    end

    it 'includes one second before the 3-day mark (n-1)' do
      invitation = create(:invitation, organisation: organisation, sent_at: 3.days.ago + 1.second)
      expect(redeemable?(invitation)).to be(true)
    end

    it 'excludes an accepted invitation' do
      invitation = create(:invitation, organisation: organisation, sent_at: 1.hour.ago, accepted_at: 1.minute.ago)
      expect(redeemable?(invitation)).to be(false)
    end

    it 'excludes a never-sent invitation' do
      invitation = build(:invitation, organisation: organisation, sent_at: nil)
      invitation.save!(validate: false)
      expect(redeemable?(invitation)).to be(false)
    end
  end

  describe '.pending and #accepted?' do
    it 'lists only invitations without accepted_at' do
      open_one = create(:invitation, organisation: organisation, accepted_at: nil)
      done = create(:invitation, organisation: organisation, accepted_at: 1.minute.ago)

      expect(described_class.pending).to contain_exactly(open_one)
      expect(open_one.accepted?).to be(false)
      expect(done.accepted?).to be(true)
    end
  end

  describe 'tenant scope' do
    it 'hides invitations of another organisation' do
      mine = create(:invitation, organisation: organisation)
      ActsAsTenant.with_tenant(create(:organisation)) { create(:invitation) }

      expect(described_class.all).to contain_exactly(mine)
    end
  end

  describe 'deleting the organisation' do
    it 'deletes its invitations' do
      create(:invitation, organisation: organisation)

      expect { ActsAsTenant.without_tenant { organisation.destroy! } }
        .to change { ActsAsTenant.without_tenant { described_class.count } }.by(-1)
    end
  end

  describe '#addressed_to?' do
    let(:invitation) { build(:invitation, organisation: organisation, email: 'Otto.Neu@Example.com') }

    it 'matches the invited address regardless of case and surrounding space' do
      expect(invitation.addressed_to?(' otto.neu@example.COM ')).to be(true)
    end

    it 'refuses any other address' do
      expect(invitation.addressed_to?('otto.neu@example.org')).to be(false)
    end

    it 'refuses a blank address, even against a blank invitation' do
      invitation.email = ''

      expect(invitation.addressed_to?('')).to be(false)
    end
  end
end
