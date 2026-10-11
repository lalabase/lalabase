# frozen_string_literal: true

require 'rails_helper'

# What: the nightly drift check of the seat event stream (M0c,
#       doc/abrechnungsmodell_plan.md §3).
# Type: Job spec.
# Why:  This job IS the alarm, and its entire value sits in the log line. So the
#       line is the contract: an ops-side watcher matches on the prefix and on
#       the severity, and neither may drift silently. Every example asserts the
#       PREFIX too, because a review found that pinning it only on the success
#       line left the alarm half renameable without a single failing test.
#
#       Three properties beyond "it notices a mismatch":
#
#       1. One broken account must not take the sweep down. SeatCounter raises
#          loudly by design (D7); for a nightly watchman that would mean no log
#          line at all, for every account, because of one.
#       2. "No basis yet" is a WARNING, a real mismatch is an ERROR. Same reason
#          staging was excluded from the schedule: an alarm that fires every
#          night is one nobody reads, and a watcher has to tell the two apart.
#       3. It must not raise, so the run always reaches its log line.
RSpec.describe SeatStreamDriftCheckJob do
  let(:organisation) { create(:organisation) }

  def add_counted_member(org)
    user = create(:user)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, active: true,
                          role: create(:role, organisation: org, billable: true))
    end
    user
  end

  # Gives the stream a basis. The delete_all first is not a trick: it reproduces
  # production's actual starting position, memberships that predate the stream,
  # which is the only state in which the backfill has anything to open.
  def open_the_stream
    SeatEvent.delete_all
    Subscriptions::SeatOpeningBackfill.call
  end

  describe 'the clean case' do
    it 'logs at info with the prefix and nothing at error level' do
      add_counted_member(organisation)
      open_the_stream

      allow(Rails.logger).to receive(:info)
      expect(Rails.logger).not_to receive(:error)

      described_class.perform_now

      expect(Rails.logger).to have_received(:info)
        .with(/\A\[seat_stream\] drift check: ok .*mismatches=0 unopened=0 errors=0/)
    end
  end

  describe 'a real mismatch' do
    before do
      user = add_counted_member(organisation)
      open_the_stream
      # Live drops to zero while the stream keeps the opening: the stream now
      # counts one too many, which is the too-high-invoice direction.
      ActsAsTenant.with_tenant(organisation) do
        organisation.memberships.find_by(user_id: user.id).update!(active: false)
      end
      SeatEvent.where(event: Subscriptions::Constants::SEAT_EVENT_DEACTIVATED).delete_all
      allow(Rails.logger).to receive(:error)
    end

    it 'logs at error, with the prefix on both lines and the signed difference' do
      described_class.perform_now

      expect(Rails.logger).to have_received(:error)
        .with(/\A\[seat_stream\] drift check: FAILED .*mismatches=1 unopened=0 errors=0/)
      expect(Rails.logger).to have_received(:error)
        .with(/\A\[seat_stream\]\s+mismatch account=\S+ live=0 stream=1 diff=\+1/)
    end

    it 'does not raise' do
      expect { described_class.perform_now }.not_to raise_error
    end
  end

  describe 'an account without an opening' do
    before do
      add_counted_member(organisation)
      SeatEvent.delete_all
      allow(Rails.logger).to receive(:warn)
    end

    # WARN, not error. A missing setup step is not a broken ledger, and mixing
    # the two leaves the watcher unable to tell "run the backfill" apart from
    # "someone has to look at this".
    it 'warns instead of erroring and names the remedy' do
      expect(Rails.logger).not_to receive(:error)

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn)
        .with(/\A\[seat_stream\] drift check: incomplete .*mismatches=0 unopened=1 errors=0/)
      expect(Rails.logger).to have_received(:warn)
        .with(/\A\[seat_stream\]\s+1 account\(s\) without an opening, run rake/)
    end

    it 'does not raise' do
      expect { described_class.perform_now }.not_to raise_error
    end
  end

  describe 'an account whose count cannot be computed' do
    let!(:healthy) { create(:organisation) }

    before do
      add_counted_member(organisation)
      add_counted_member(healthy)
      open_the_stream

      broken = instance_double(Subscriptions::SeatCounter)
      allow(broken).to receive(:call).and_raise(ActiveRecord::StatementInvalid, 'kaputt')
      allow(Subscriptions::SeatCounter).to receive(:new).and_call_original
      allow(Subscriptions::SeatCounter).to receive(:new).with(organisation.account)
                                                        .and_return(broken)
      allow(Rails.logger).to receive(:error)
    end

    # The property that matters: the alarm still speaks. Before this, the whole
    # sweep died on the first broken account and produced no line at all.
    it 'reports the failure and keeps checking the other accounts' do
      expect { described_class.perform_now }.not_to raise_error

      expect(Rails.logger).to have_received(:error)
        .with(/\A\[seat_stream\] drift check: FAILED .*errors=1/)
      expect(Rails.logger).to have_received(:error)
        .with(/\A\[seat_stream\]\s+error account=#{organisation.account.id} ActiveRecord::StatementInvalid/)
    end
  end

  describe 'truncation' do
    # A silent cap reads as "that was all of them".
    it 'says so when it stops naming' do
      stub_const("#{described_class}::MAX_NAMED", 1)
      second = create(:organisation)
      add_counted_member(organisation)
      add_counted_member(second)
      open_the_stream
      # Both accounts now hold an opening; taking the live seats away leaves two
      # mismatches, one more than MAX_NAMED.
      Membership.update_all(active: false)
      allow(Rails.logger).to receive(:error)

      described_class.perform_now

      expect(Rails.logger).to have_received(:error)
        .with(/\A\[seat_stream\]\s+named 1 of 2 mismatches, rest omitted/)
    end
  end
end
