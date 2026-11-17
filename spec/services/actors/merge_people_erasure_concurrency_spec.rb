# frozen_string_literal: true

require 'rails_helper'

# A soft-deleted users row still satisfies a foreign key. Merges and both erasure
# paths must therefore serialize before resolving/writing account references, including
# the merge's owner. These examples use committed fixtures and two real connections.
RSpec.describe 'Merging people during account erasure', :ci_guard, :real_transactions do
  include AllPeopleHelpers

  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }
  let(:owner) { create(:user, first_name: 'Vera', last_name: 'Viewer') }
  let(:member) { create(:user, first_name: 'Mara', last_name: 'Mitglied') }

  before do
    Prosopite.pause
    @threads = []
    @gates = []
    [north, south].each { |organisation| join_organisation(owner, organisation, admin: true) }
    join_organisation(member, north)
  end

  after do
    @gates.each { |gate| gate << true }
    @threads.each do |thread|
      thread.join(5)
      thread.kill if thread.alive?
    end
    Prosopite.resume
  end

  def start_on_connection(&work)
    started = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        started << connection.select_value('SELECT pg_backend_pid()')
        work.call
      end
    end
    @threads << thread
    [thread, Timeout.timeout(10) { started.pop }]
  end

  def pause_after(object, method)
    ready = Queue.new
    gate = Queue.new
    @gates << gate
    allow(object).to receive(method).and_wrap_original do |original, *args|
      result = original.call(*args)
      ready << true
      gate.pop
      result
    end
    [ready, gate]
  end

  def wait_for_lock(pid)
    Timeout.timeout(10) do
      loop do
        break if ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)}))").positive?

        sleep 0.01
      end
    end
  end

  def result_of(thread)
    expect(thread.join(10)).not_to be_nil
    thread.value
  end

  def merge_for(northern)
    southern = person_in(south, name: 'Mara Kontakt')
    Actors::MergePeople.new(entries: [northern, { org: south.id, id: "person:#{southern.id}" }], current_user: User.find(owner.id))
  end

  %i[permission account].each do |changed|
    it "rechecks the #{changed} after waiting for the owner's merge lock" do
      northern = person_in(north, name: 'Nord Kontakt')
      merge = merge_for({ org: north.id, id: "person:#{northern.id}" })
      ready = Queue.new
      gate = Queue.new
      @gates << gate
      holding, = start_on_connection do
        User.transaction do
          PersonGroup.lock_for(owner)
          ready << true
          gate.pop
        end
      end
      Timeout.timeout(10) { ready.pop }
      merging, pid = start_on_connection { merge.call }
      wait_for_lock(pid)

      if changed == :permission
        take_people_right(owner, north)
      else
        ActsAsTenant.with_tenant(north) { northern.update!(user: member) }
      end
      gate << true

      result_of(holding)
      expect(result_of(merging).code).to eq(changed == :permission ? :not_found : :conflict)
      expect(PersonGroup.count).to eq(0)
    end
  end

  [true, false].each do |merged|
    it "keeps a takeover's owner lock through the outer commit when the nested merge #{merged ? 'succeeds' : 'rolls back'}" do
      source = person_in(north, name: 'Kopie')
      unless merged
        existing = person_in(south, name: 'Anderer Name')
        group = create(:person_group, owner: owner)
        create(:person_group_entry, person_group: group, organisation: north, person_id: source.id)
        create(:person_group_entry, person_group: group, organisation: south, person_id: existing.id)
      end
      takeover = Actors::TakeOverPerson.new(source_organisation: north, person_id: source.id, target_organisation_id: south.id,
                                            fields: [], confirm_duplicate: false, current_user: User.find(owner.id))
      deleting_account = User.find(owner.id)
      ready, gate = pause_after(takeover, :perform)
      copying, = start_on_connection { takeover.call }
      Timeout.timeout(10) { ready.pop }
      erasing, pid = start_on_connection { deleting_account.soft_delete_and_anonymize! }
      wait_for_lock(pid)
      gate << true

      result = result_of(copying)
      expect(result).to be_success
      expect(result.code).to eq(merged ? :ok : :not_merged)
      result_of(erasing)
      expect(PersonGroup.where(owner_id: owner.id)).not_to exist
      expect(User.unscoped.find(owner.id).deleted_at).to be_present
    end
  end

  %i[merge erasure].each do |concurrent|
    it "lets last-membership removal finish its user update while #{concurrent} waits" do
      row = person_in(north, user: member, name: 'Mara Mitglied')
      group = create(:person_group, owner: owner)
      create(:person_group_entry, person_group: group, organisation: north, user_id: member.id)
      other = create(:person_group, owner: owner)
      create(:person_group_entry, person_group: other, organisation: north, person_id: row.id)
      membership = ActsAsTenant.with_tenant(north) { Membership.find_by!(user: member, organisation: north) }
      removal = RemoveMembershipService.new(membership: membership, admin: User.find(owner.id))
      merge = merge_for({ org: north.id, id: "member:#{member.id}" })
      deleting_account = User.find(member.id)
      ready, gate = pause_after(removal.target_user, :should_be_recommended_for_deletion?)
      removing, = start_on_connection { ActsAsTenant.with_tenant(north) { removal.call } }
      Timeout.timeout(10) { ready.pop }
      competing, pid = start_on_connection do
        concurrent == :merge ? merge.call : deleting_account.soft_delete_and_anonymize!
      end
      wait_for_lock(pid)
      gate << true

      expect(result_of(removing)).to be(true), removal.errors.inspect
      result = result_of(competing)
      expect(result.code).to eq(:not_found) if concurrent == :merge
      expect(Membership.where(id: membership.id)).not_to exist
      expect(User.unscoped.find(member.id).deletion_recommended).to be(true)
    end
  end

  it 'lets the signup purge wait for a merge before taking its confirmation row lock' do
    owner.update_column(:confirmed_at, nil)
    source = person_in(north, name: 'Nord Kontakt')
    merge = merge_for({ org: north.id, id: "person:#{source.id}" })
    deleting_account = User.find(owner.id)
    purge = UnconfirmedSignupPurgeJob.new
    allow(purge).to receive(:enforce?).and_return(true)
    # Pause before the inserts: their FK checks still need the users row, which the
    # purge must not lock while waiting for this merge's shared account lock.
    ready, gate = pause_after(merge, :lock_accounts)
    merging, = start_on_connection { merge.call }
    Timeout.timeout(10) { ready.pop }
    purging, pid = start_on_connection { purge.send(:erase, deleting_account, []) }
    wait_for_lock(pid)
    gate << true

    expect(result_of(merging)).to be_success
    expect(result_of(purging)).to be(true)
    expect(PersonGroup.where(owner_id: owner.id)).not_to exist
    expect(User.unscoped.find(owner.id).deleted_at).to be_present
  end

  [User, Admin::User].each do |erasure_class|
    [true, false].each do |active|
      it "coordinates #{erasure_class} erasure with a linked #{active ? 'active' : 'deactivated'} member" do
        row = person_in(north, user: member, name: 'Mara Mitglied')
        ActsAsTenant.with_tenant(north) { Membership.find_by!(user: member, organisation: north).update!(active: false) } unless active
        merge = merge_for({ org: north.id, id: "person:#{row.id}" })
        deleting_account = erasure_class.find(member.id)
        ready, gate = pause_after(merge, :sweep)
        merging, = start_on_connection { merge.call }
        Timeout.timeout(10) { ready.pop }
        erasing, pid = start_on_connection { deleting_account.soft_delete_and_anonymize! }
        wait_for_lock(pid)
        gate << true

        expect(result_of(merging)).to be_success
        result_of(erasing)
        expect(PersonGroupEntry.where(person_id: row.id)).not_to exist
        expect(PersonGroupEntry.where(user_id: member.id)).not_to exist
      end
    end
    %i[owner member].each do |erased|
      context "when #{erasure_class} erases the #{erased}" do
        let(:account) { erasure_class.find(public_send(erased).id) }
        let(:actor) do
          southern = person_in(south, name: 'Mara Kontakt')
          northern = if erased == :owner
                       { org: north.id, id: "person:#{person_in(north, name: 'Kai Kontakt').id}" }
                     else
                       { org: north.id, id: "member:#{member.id}" }
                     end
          Actors::MergePeople.new(entries: [northern, { org: south.id, id: "person:#{southern.id}" }], current_user: User.find(owner.id))
        end

        def expect_erased
          expect(User.unscoped.find(account.id).deleted_at).to be_present
          expect(PersonGroup.where(owner_id: account.id)).not_to exist
          expect(PersonGroupEntry.where(owner_id: account.id)).not_to exist
          expect(PersonGroupEntry.where(user_id: account.id)).not_to exist
        end

        it 'waits for the uncommitted merge, then erases its references too' do
          merge = actor
          deleting_account = account
          ready, gate = pause_after(merge, :sweep)
          merging, = start_on_connection { merge.call }
          Timeout.timeout(10) { ready.pop }

          erasing, pid = start_on_connection { deleting_account.soft_delete_and_anonymize! }
          wait_for_lock(pid)
          gate << true

          expect(result_of(merging)).to be_success
          result_of(erasing)
          expect_erased
        end

        it 'revalidates after waiting for an erasure and refuses to store the old reference' do
          merge = actor
          deleting_account = account
          ready, gate = pause_after(deleting_account, :erase_person_groups!)
          erasing, = start_on_connection { deleting_account.soft_delete_and_anonymize! }
          Timeout.timeout(10) { ready.pop }

          merging, pid = start_on_connection { merge.call }
          wait_for_lock(pid)
          gate << true

          result_of(erasing)
          expect(result_of(merging)).not_to be_success
          expect_erased
          expect(PersonGroup.count).to eq(0)
        end
      end
    end
  end
end
