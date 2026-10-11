# frozen_string_literal: true

require 'rails_helper'

# What: the one-time opening state of the seat event stream (M0b,
#       doc/abrechnungsmodell_plan.md §3).
# Type: service spec.
# Why:  This run is the foundation every later billing figure stands on, and its
#       failure mode is silence. Measured on production before it existed:
#       SeatCounter said 3 for an account, a reconstruction from the stream said
#       0, and nothing anywhere was red. The property that matters is therefore
#       not "it writes rows" but "afterwards the stream agrees with reality" --
#       which is what the last example here asserts, and what the rake task runs
#       automatically after every real backfill.
RSpec.describe Subscriptions::SeatOpeningBackfill do
  let(:organisation) { create(:organisation) }
  let(:account) { organisation.account }

  def add_member(org, billable: true, active: true)
    user = create(:user)
    ActsAsTenant.with_tenant(org) do
      role = create(:role, organisation: org, billable: billable)
      create(:membership, user: user, organisation: org, role: role, active: active)
    end
    user
  end

  # The recorder fires on every membership write, so a plain create already
  # leaves an `activated` behind. Clearing the table reproduces the real starting
  # position: memberships that predate the stream and have no history at all.
  def simulate_stream_started_late
    SeatEvent.delete_all
  end

  describe 'what it writes' do
    it 'gives every counted membership without history an opening' do
      user = add_member(organisation)
      simulate_stream_started_late

      expect { described_class.call }.to change(SeatEvent, :count).by(1)

      event = SeatEvent.last
      expect(event).to have_attributes(
        event: Subscriptions::Constants::SEAT_EVENT_OPENING,
        account_id: account.id, organisation_id: organisation.id, user_id: user.id,
        counted: true, billable: true, organisation_name: organisation.name
      )
    end

    it 'skips a membership that is not counted' do
      add_member(organisation, billable: false)
      add_member(organisation, active: false)
      simulate_stream_started_late

      expect { described_class.call }.not_to change(SeatEvent, :count)
    end

    # A pair that already carries history reconstructs on its own. An extra
    # opening would restate it with a LATER timestamp and could even overwrite a
    # deactivation, which is the dangerous direction.
    it 'leaves a pair that already has an event alone' do
      user = add_member(organisation)
      ActsAsTenant.with_tenant(organisation) do
        organisation.memberships.find_by(user_id: user.id).update!(active: false)
      end
      before_count = SeatEvent.count

      described_class.call

      expect(SeatEvent.count).to eq(before_count)
      expect(SeatEvent.where(event: Subscriptions::Constants::SEAT_EVENT_OPENING)).to be_empty
    end

    it 'writes one shared timestamp for the whole run, not one per row' do
      3.times { add_member(organisation) }
      simulate_stream_started_late

      described_class.call

      expect(SeatEvent.distinct.pluck(:occurred_at).size).to eq(1)
    end

    it 'writes nothing on a dry run but reports what it would do' do
      add_member(organisation)
      simulate_stream_started_late

      result = nil
      expect { result = described_class.call(dry_run: true) }.not_to change(SeatEvent, :count)
      expect(result.written).to eq(1)
    end

    # The property the plan asks for by name. Without it a second run doubles
    # every seat, and the doubling looks exactly like real growth.
    it 'is idempotent' do
      2.times { add_member(organisation) }
      simulate_stream_started_late
      described_class.call

      expect { described_class.call }.not_to change(SeatEvent, :count)
    end
  end

  # Role is acts_as_tenant(:organisation): its billable flag only resolves under
  # its own organisation's tenant. A backfill that iterates accounts runs without
  # one, so a missing with_tenant would silently find no billable roles at all
  # and write nothing -- the exact failure this run exists to prevent.
  describe 'across several organisations of one account' do
    let(:sibling) { create(:organisation, account: account) }

    it 'covers every organisation and deduplicates the shared user' do
      shared = add_member(organisation)
      ActsAsTenant.with_tenant(sibling) do
        create(:membership, user: shared, organisation: sibling, active: true,
                            role: create(:role, organisation: sibling, billable: true))
      end
      add_member(sibling)
      simulate_stream_started_late

      described_class.call

      # Three memberships, three rows: the stream records PAIRS. The dedup to two
      # seats happens on read, and the next example proves it does.
      expect(SeatEvent.count).to eq(3)
      expect(SeatEvent.distinct.count(:user_id)).to eq(2)
    end
  end

  # The acceptance test from §3, and the only one that would have caught the
  # production finding.
  describe 'afterwards the stream agrees with the live count' do
    let(:sibling) { create(:organisation, account: account) }

    it 'matches SeatCounter for every account' do
      shared = add_member(organisation)
      ActsAsTenant.with_tenant(sibling) do
        create(:membership, user: shared, organisation: sibling, active: true,
                            role: create(:role, organisation: sibling, billable: true))
      end
      add_member(sibling)
      add_member(organisation, billable: false)
      simulate_stream_started_late

      expect(Subscriptions::SeatStreamDrift.call).not_to be_empty

      described_class.call

      expect(Subscriptions::SeatStreamDrift.call).to be_empty
      expect(SeatEvent.counted_user_ids_for(account: account).size)
        .to eq(Subscriptions::SeatCounter.new(account).call)
    end
  end
end
