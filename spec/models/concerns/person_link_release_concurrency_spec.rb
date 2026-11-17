# frozen_string_literal: true

require 'rails_helper'

# What: a member leaves an organisation while somebody who merged that member is writing
#       another merge, on two connections.
# Why:  the callback of the membership moves entries between two groups of that owner when
#       the owner named the member twice (by account and by row). A merge of the same owner
#       that has not committed yet is invisible to it; without the owner's lock the move
#       ran into the unique index once the merge committed, and the exception kept the
#       membership (and an account erasure, which removes memberships the same way).
#       Somebody's private note must never stop a member from leaving.
RSpec.describe PersonLinkRelease, :ci_guard do
  include AllPeopleHelpers

  self.use_transactional_tests = false

  before do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:east) { create(:organisation, name: 'Ost eG') }
  let(:west) { create(:organisation, name: 'West KG') }
  let(:owner) { create(:user, first_name: 'Vera', last_name: 'Viewer') }
  let(:mara) { create(:user, first_name: 'Mara', last_name: 'Mitglied') }

  def group_of(*entries)
    create(:person_group, owner: owner).tap do |group|
      entries.each { |organisation, address| create(:person_group_entry, person_group: group, organisation: organisation, **address) }
    end
  end

  def entries_of(group)
    PersonGroupEntry.where(person_group_id: group.id).pluck(:organisation_id, :person_id, :user_id)
  end

  it 'removes the membership when the owner of two merges of that member is merging at the same moment' do
    [north, east, west].each { |organisation| join_organisation(owner, organisation, admin: true) }
    join_organisation(mara, north)
    row = person_in(north, user: mara, name: 'Mara Mitglied')
    east_one = person_in(east, name: 'Ost Eins')
    western = person_in(west, name: 'Wanda West')
    by_account = group_of([north, { user_id: mara.id }], [east, { person_id: east_one.id }])
    by_row = group_of([north, { person_id: row.id }], [west, { person_id: western.id }])

    # The merge persists the grouping already displayed: the account group's eastern
    # source moves into the row group. The removal must wait for that uncommitted move.
    merge = Actors::MergePeople.new(entries: [{ org: west.id, id: "person:#{western.id}" }, { org: east.id, id: "person:#{east_one.id}" }],
                                    current_user: User.find(owner.id))
    ready = Queue.new
    release = Queue.new
    allow(merge).to receive(:sweep).and_wrap_original do |sweep|
      ready << true
      release.pop
      sweep.call
    end
    merging = Thread.new { ActiveRecord::Base.connection_pool.with_connection { merge.call } }
    Timeout.timeout(10) { ready.pop }
    releasing = Thread.new do
      sleep 0.5
      release << true
    end

    leaving = lambda do
      ActsAsTenant.with_tenant(north) { Membership.find_by!(user_id: mara.id, organisation_id: north.id).destroy! }
    end

    expect { Timeout.timeout(15) { leaving.call } }.not_to raise_error
    expect(merging.join(10)&.value).to be_success

    expect(Membership.where(user_id: mara.id, organisation_id: north.id)).not_to exist
    expect(ActsAsTenant.with_tenant(north) { Person.find(row.id).user_id }).to be_nil
    expect(entries_of(by_row)).to contain_exactly([north.id, row.id, nil], [west.id, western.id, nil], [east.id, east_one.id, nil])
    expect(entries_of(by_account)).to be_empty
    expect(PersonGroupEntry.where(user_id: mara.id)).not_to exist
  ensure
    release << true if release
    [merging, releasing].each do |thread|
      thread&.join(2)
      thread&.kill if thread&.alive?
    end
  end
end
