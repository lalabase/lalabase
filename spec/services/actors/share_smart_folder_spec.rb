# frozen_string_literal: true

require 'rails_helper'

# Actors::ShareSmartFolder shares a folder with a set of users all-or-nothing:
# either every share is created in one transaction or none is. IDOR-rescoping of
# `users` is the caller's job; the actor trusts the relation it is handed.
RSpec.describe Actors::ShareSmartFolder do
  let(:organisation) { create(:organisation) }
  let(:role) { create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true) }
  let(:owner) { member }
  let(:colleague_a) { member }
  let(:colleague_b) { member }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def member
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  let(:folder) { create(:smart_folder, user: owner, organisation: organisation) }

  def share(users:, **opts)
    described_class.new(smart_folder: folder, users: users, current_user: owner, **opts)
  end

  it 'creates a share for every given user and reports the count' do
    actor = share(users: [colleague_a, colleague_b])
    result = actor.call

    expect(result).to be_success
    expect(actor.count).to eq(2)
    expect(folder.shared_users).to contain_exactly(colleague_a, colleague_b)
  end

  it 'never shares with the owner (skipped, not counted)' do
    actor = share(users: [owner, colleague_a])
    actor.call

    expect(actor.count).to eq(1)
    expect(folder.smart_folder_shares.where(user_id: owner.id)).to be_empty
  end

  it 'propagates the can_edit / can_share flags' do
    share(users: [colleague_a], can_edit: true, can_share: true).call

    share_record = folder.smart_folder_shares.sole
    expect(share_record).to have_attributes(can_edit: true, can_share: true)
  end

  it 'is all-or-nothing: one unshareable user rolls back every share' do
    non_member = create(:user) # not a member of the organisation → share_with returns false

    actor = share(users: [colleague_a, non_member])
    result = actor.call

    expect(result).not_to be_success
    expect(folder.smart_folder_shares.reload).to be_empty
  end
end
