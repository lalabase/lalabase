# frozen_string_literal: true

require 'rails_helper'

# What: Notifications::InboxQuery.stamp, the opaque state of a person's in-app rows
#       that the inbox above the organisations draws with its list and receives as
#       its live signal (Notifications::Streams.all_inboxes).
# Why:  the page compares the two: equal means "this is the echo of what I drew",
#       different means "something changed, show the banner". A stamp that stays
#       the same after a change leaves the page stale; one that changes without a
#       change raises a banner after every own click. And it travels over a stream,
#       so it must not carry a count or an id.
RSpec.describe Notifications::InboxQuery, '.stamp', :ci_guard do
  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nordwind GmbH') }
  let(:south) { create(:organisation, name: 'Suedhang AG') }

  def row(org, recipient: user, state: :delivered, channel: 'in_app')
    ActsAsTenant.with_tenant(org) do
      create(:notification, recipient: recipient, organisation: org, project: nil,
                            event_type: 'mention', channel: channel, state: state)
    end
  end

  def stamp
    described_class.stamp(user: user, reach: PersonalAccessToken::Reach.for_person(user))
  end

  before do
    Prosopite.pause
    make_token_owner_a_member(user, north, projects: [])
    make_token_owner_a_member(user, south, projects: [])
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  let!(:north_row) { row(north) }

  it 'is the same for the same rows' do
    expect(stamp).to eq(stamp)
  end

  it 'says nothing about the rows: no count, no id, a fixed length of hex' do
    value = stamp

    expect(value).to match(/\A\h{#{described_class::STAMP_LENGTH}}\z/o)
    expect(value).not_to include(north_row.id.delete('-').first(8))
  end

  it 'changes when a row arrives' do
    before = stamp
    row(south)

    expect(stamp).not_to eq(before)
  end

  it 'changes when a row is read, made unread, archived and brought back' do
    seen = [stamp]
    ActsAsTenant.with_tenant(north) do
      north_row.mark_as_read!
      seen << stamp
      north_row.mark_as_unread!
      seen << stamp
      north_row.archive!
      seen << stamp
      north_row.update!(state: :read, archived_at: nil)
      seen << stamp
    end

    expect(seen.each_cons(2).map { |a, b| a == b }).to all(be(false))
  end

  # update_all leaves updated_at alone; each row's state still sees the move.
  it 'changes after a bulk change' do
    before = stamp
    ActsAsTenant.without_tenant do
      Notification.where(id: north_row.id).bulk_transition!(state: 'read', read_at: Time.current)
    end

    expect(stamp).not_to eq(before)
  end

  it 'changes when a new event joins a group' do
    before = stamp
    ActsAsTenant.with_tenant(north) { north_row.update!(last_event_at: 1.minute.from_now, group_count: 2) }

    expect(stamp).not_to eq(before)
  end

  it 'sees an older group update that becomes visible after a newer one' do
    older_write_at = 1.minute.ago
    newer_row = row(south)
    ActsAsTenant.with_tenant(south) { newer_row.update!(updated_at: Time.current) }
    before = stamp

    # Reproduce the committed snapshots: this write's timestamp was assigned
    # before newer_row's, but its transaction becomes visible only now.
    ActsAsTenant.with_tenant(north) do
      north_row.update!(last_event_at: older_write_at, group_count: 2, updated_at: older_write_at)
    end
    expect(north_row.updated_at).to be < newer_row.updated_at
    expect(stamp).not_to eq(before)
  end

  it 'uses the same empty stamp for an empty inbox and an empty reach' do
    ActsAsTenant.with_tenant(north) { north_row.destroy! }
    empty_reach = PersonalAccessToken::Reach.new(project_ids_by_organisation: {})

    expect(described_class.stamp(user: user, reach: empty_reach)).to eq(stamp)
  end

  it 'sees bulk state exchanges even when state counts and their newest rows stay the same' do
    older_read = row(south, state: :read)
    row(north)
    row(south, state: :read)
    before = stamp

    ActsAsTenant.without_tenant do
      Notification.where(id: north_row.id).bulk_transition!(state: 'read')
      Notification.where(id: older_read.id).bulk_transition!(state: 'delivered')
    end

    expect(stamp).not_to eq(before)
  end

  it 'stays when a row of another person, a mail row or a row outside the reach arrives' do
    before = stamp
    stranger = create(:user)
    make_token_owner_a_member(stranger, north, projects: [])
    row(north, recipient: stranger)
    row(north, channel: 'email')
    elsewhere = create(:organisation, name: 'Fremd KG')
    row(elsewhere)

    expect(stamp).to eq(before)
  end

  # The same rule as the list (.reading): what the person may not see changes nothing.
  it 'stays when a row arrives in a project the person may not read' do
    before = stamp
    hidden = ActsAsTenant.with_tenant(north) { create(:project, organisation: north) }
    ActsAsTenant.with_tenant(north) do
      create(:notification, recipient: user, organisation: north, project: hidden,
                            event_type: 'mention', channel: 'in_app', state: :delivered)
    end

    expect(stamp).to eq(before)
  end

  it 'leaves a deactivated membership out of the reach' do
    before = stamp
    ActsAsTenant.without_tenant { Membership.find_by!(user: user, organisation: south).update!(active: false) }
    row(south)

    expect(stamp).to eq(before)
  end
end
