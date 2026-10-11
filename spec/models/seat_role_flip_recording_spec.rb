# frozen_string_literal: true

require 'rails_helper'

# P1 from doc/abrechnungsmodell_plan.md §9: a flip of Role#billable moves the
# counted state of EVERY membership of that role without saving a single
# membership, so the membership callbacks structurally cannot see it.
#
# The plan wrote this test as "has to start red in the guest-role strand". It
# does: before SeatRoleFlipRecording existed, every example below found an empty
# stream while SeatCounter had already changed its answer.
#
# The drift goes towards a TOO HIGH invoice -- the seats keep counting in the
# stream after they stopped counting for real -- which is the direction that
# reaches a customer.
RSpec.describe SeatRoleFlipRecording do
  let(:organisation) { create(:organisation) }
  let(:account) { organisation.account }
  let(:role) { create(:role, organisation: organisation, billable: true) }

  # Role is tenant-scoped (role.rb:25). Membership and SeatEvent are not,
  # billing lives above the tenants, so this only enables the fixtures.
  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def events_for(user)
    SeatEvent.where(organisation_id: organisation.id, user_id: user.id).chronological
  end

  def membership_for(user, active: true, on: role)
    create(:membership, user: user, organisation: organisation, role: on, active: active)
  end

  describe 'flipping a role to non-billable' do
    it 'writes a deactivated event for every counted membership of that role' do
      first = create(:user)
      second = create(:user)
      membership_for(first)
      membership_for(second)

      expect { role.update!(billable: false) }
        .to change { SeatEvent.for_account(account).where(event: 'deactivated').count }.by(2)

      # One query, not one per user: asserting in a loop trips Prosopite, and
      # the property under test is about the SET of rows anyway.
      written = SeatEvent.for_account(account)
                         .where(event: Subscriptions::Constants::SEAT_EVENT_DEACTIVATED)
      expect(written.map(&:user_id)).to match_array([first.id, second.id])
      expect(written).to all(have_attributes(
                               counted: false,
                               billable: false,
                               role_id: role.id,
                               organisation_name: organisation.name
                             ))
    end

    it 'leaves the reconstruction in agreement with SeatCounter' do
      # The property the whole stream exists for. Asserted on the two SOURCES,
      # not on a row count, because a row count can be right while the
      # reconstruction disagrees.
      membership_for(create(:user))
      membership_for(create(:user))

      role.update!(billable: false)

      expect(SeatEvent.counted_user_ids_for(account: account).size)
        .to eq(Subscriptions::SeatCounter.new(account).call)
    end

    it 'ignores inactive memberships -- they were never a counted seat' do
      membership_for(create(:user), active: false)

      expect { role.update!(billable: false) }.not_to(change { SeatEvent.for_account(account).count })
    end

    it 'ignores memberships of OTHER roles in the same organisation' do
      other_role = create(:role, organisation: organisation, title: 'other', billable: true)
      untouched = create(:user)
      membership_for(untouched, on: other_role)

      expect { role.update!(billable: false) }.not_to(change { SeatEvent.for_account(account).count })
      expect(events_for(untouched).map(&:event))
        .to eq([Subscriptions::Constants::SEAT_EVENT_ACTIVATED])
    end
  end

  describe 'flipping a role back to billable' do
    it 'writes an activated event that counts again' do
      user = create(:user)
      membership_for(user)
      role.update!(billable: false)

      role.update!(billable: true)

      expect(events_for(user).map(&:event)).to eq(
        [Subscriptions::Constants::SEAT_EVENT_ACTIVATED,
         Subscriptions::Constants::SEAT_EVENT_DEACTIVATED,
         Subscriptions::Constants::SEAT_EVENT_ACTIVATED]
      )
      expect(events_for(user).map(&:counted)).to eq([true, false, true])
    end
  end

  describe 'saves that do not move any seat' do
    it 'writes nothing when a different attribute changes' do
      membership_for(create(:user))

      expect { role.update!(description: 'neue Beschreibung') }
        .not_to(change { SeatEvent.for_account(account).count })
    end

    it 'writes nothing when the role has no memberships at all' do
      expect { role.update!(billable: false) }.not_to(change { SeatEvent.count })
    end
  end

  describe 'a second save of the same role in the same transaction' do
    # after_commit fires once per record per transaction, and saved_change_to_*
    # only knows the LAST save. Reading the flip there loses it entirely as soon
    # as anything saves the role again -- a rename in the same submit, a sync
    # that touches it. Measured before the fix: 0 rows written, stream 1,
    # SeatCounter 0.
    it 'still records the flip when a harmless save follows it' do
      membership_for(create(:user))

      Role.transaction do
        role.update!(billable: false)
        role.update!(description: 'im selben Vorgang umbenannt')
      end

      expect(SeatEvent.for_account(account)
                      .where(event: Subscriptions::Constants::SEAT_EVENT_DEACTIVATED).count).to eq(1)
      expect(SeatEvent.counted_user_ids_for(account: account).size)
        .to eq(Subscriptions::SeatCounter.new(account).call)
    end

    it 'records NOTHING when the flip is undone before the commit' do
      # The stream records what the committed state IS, not the path taken to it.
      membership_for(create(:user))

      expect do
        Role.transaction do
          role.update!(billable: false)
          role.update!(billable: true)
        end
      end.not_to(change { SeatEvent.for_account(account).count })
    end
  end

  describe 'the timestamp of one flip' do
    # A7: the peak calculation must not depend on the insertion order of
    # simultaneous events. One flip is ONE moment, not a smear across however
    # long the write loop took, so every row of it shares occurred_at.
    it 'is a single moment shared by all rows of that flip' do
      membership_for(create(:user))
      membership_for(create(:user))

      role.update!(billable: false)

      stamps = SeatEvent.for_account(account)
                        .where(event: Subscriptions::Constants::SEAT_EVENT_DEACTIVATED)
                        .pluck(:occurred_at)
      expect(stamps.size).to eq(2)
      expect(stamps.uniq.size).to eq(1)
    end
  end

  describe 'the admin twin' do
    # Same reason as SeatEventRecording on Admin::Membership (incident 3 in
    # spec/models/admin_twin_concern_parity_guard_spec.rb): the two classes never
    # share a save cycle, so a callback on one side is silence on the other.
    it 'records the flip when the role is saved through Admin::Role' do
      user = create(:user)
      membership_for(user)

      ActsAsTenant.without_tenant { Admin::Role.find(role.id).update!(billable: false) }

      expect(events_for(user).last).to have_attributes(
        event: Subscriptions::Constants::SEAT_EVENT_DEACTIVATED,
        counted: false
      )
    end
  end
end
