# frozen_string_literal: true

require 'rails_helper'

# What: the comparison of the seat event stream against the live count (M0b/M0c,
#       doc/abrechnungsmodell_plan.md §3).
# Type: service spec.
# Why:  This is the acceptance test of the backfill AND the only net under the
#       known hole in the writer: a flip of Role#billable changes the counted
#       state of every membership on that role without touching a membership, so
#       no callback fires and no event is written. The flag has no UI today,
#       which is the only reason the hole is shut, and the guest-role work that
#       opens it is a precondition for the first paying customer.
#
#       The rake spec only pins one direction (live=1, stream=0). What matters
#       here is the SIGN convention and the `at:` parameter, because a consumer
#       reading a drift the wrong way round would chase the wrong side.
RSpec.describe Subscriptions::SeatStreamDrift do
  let(:organisation) { create(:organisation) }
  let(:account) { organisation.account }

  # Reproduces production's actual starting position: memberships that predate
  # the stream, so the backfill has something to open. Without it every account
  # is `not_reconstructible` and no mismatch can be observed at all.
  def open_the_stream
    SeatEvent.delete_all
    Subscriptions::SeatOpeningBackfill.call
  end

  def add_counted_member(org)
    user = create(:user)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, active: true,
                          role: create(:role, organisation: org, billable: true))
    end
    user
  end

  it 'reports nothing while stream and counter agree' do
    add_counted_member(organisation)
    open_the_stream

    expect(described_class.call).to be_empty
  end

  # Before the backfill the stream has no basis, and calling that a mismatch
  # would blame the data for a run that never happened. Kept apart because the
  # two want different reactions: this one wants a rake task, a mismatch wants a
  # person.
  it 'marks an account without a basis instead of calling it a mismatch' do
    add_counted_member(organisation)
    SeatEvent.delete_all

    finding = described_class.call.sole

    expect(finding).to be_not_reconstructible
    expect(finding.kind).to eq(described_class::KIND_NOT_RECONSTRUCTIBLE)
  end

  # The production starting position: memberships that predate the stream.
  # A real mismatch WITH a basis: the opening stays, so the stream is
  # reconstructible, and the second member's arrival is what went missing. That
  # is the shape a writer gap produces, and it must not be confused with the
  # no-basis case above -- which is why the kind is asserted too.
  it 'reports an account whose stream knows less than reality' do
    add_counted_member(organisation)
    open_the_stream
    add_counted_member(organisation)
    SeatEvent.where(event: Subscriptions::Constants::SEAT_EVENT_ACTIVATED).delete_all

    finding = described_class.call.sole

    expect(finding).to have_attributes(account: account, kind: described_class::KIND_MISMATCH,
                                       live: 2, from_stream: 1)
    expect(finding.difference).to eq(-1)
  end

  # The sign, pinned in the direction that costs money. `difference` is
  # stream minus live, so POSITIVE means the stream counts too many, which is the
  # too-high invoice. A consumer that reads it the other way round would look for
  # the fault on the wrong side.
  it 'signs a stream that counts too many positively' do
    user = add_counted_member(organisation)
    open_the_stream
    ActsAsTenant.with_tenant(organisation) do
      organisation.memberships.find_by(user_id: user.id).update!(active: false)
    end
    # The membership is gone from the live count; the stream still carries the
    # activation because we drop the deactivation that followed it.
    SeatEvent.where(event: Subscriptions::Constants::SEAT_EVENT_DEACTIVATED).delete_all

    finding = described_class.call.sole

    expect(finding).to have_attributes(live: 0, from_stream: 1)
    expect(finding.difference).to eq(1)
  end

  # Without an honoured `at:` the check could only ever ask about now, and M0c
  # plus every period computation needs to ask about a past boundary.
  # `not_to be_empty` alone would also pass with the WRONG kind, and the wrong
  # kind is the whole point here: for a moment before the stream became complete
  # the reconstruction is empty by construction, and the plan (§3) says that has
  # to be named as a gap rather than reported as a data defect. The next consumer
  # is the period billing, and it asks about exactly such past boundaries.
  it 'calls a moment before the stream began not reconstructible, not a mismatch' do
    add_counted_member(organisation)
    open_the_stream

    finding = described_class.call(at: 1.day.ago).sole

    expect(finding).to be_not_reconstructible
    expect(finding.from_stream).to be_nil
    expect(described_class.call).to be_empty
  end

  # from_stream stays nil when nothing was read, so `difference` must not invent
  # one. A -2 here would read as "the stream is two short" when the truth is
  # "nobody looked".
  it 'has no difference where there is no stream figure' do
    add_counted_member(organisation)
    SeatEvent.delete_all

    expect(described_class.call.sole.difference).to be_nil
  end

  # One broken account must not take the sweep down: SeatCounter raises loudly by
  # design (D7), and for the nightly watchman that would mean no report at all.
  it 'turns a raising account into a finding and keeps going' do
    healthy = create(:organisation)
    add_counted_member(organisation)
    add_counted_member(healthy)
    open_the_stream
    counter = instance_double(Subscriptions::SeatCounter)
    allow(counter).to receive(:call).and_raise(ActiveRecord::StatementInvalid, 'kaputt')
    allow(Subscriptions::SeatCounter).to receive(:new).and_call_original
    allow(Subscriptions::SeatCounter).to receive(:new).with(account).and_return(counter)

    findings = described_class.call

    expect(findings.size).to eq(1)
    expect(findings.sole).to be_failed
    expect(findings.sole.error).to include('ActiveRecord::StatementInvalid')
  end
end
