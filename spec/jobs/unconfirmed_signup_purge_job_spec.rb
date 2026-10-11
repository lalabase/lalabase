# frozen_string_literal: true

require 'rails_helper'

# What: UnconfirmedSignupPurgeJob — removes self-registrations that never proved
#       their address (doc/bot_registrierungen_plan.md S4).
# Type: Job spec.
# Why:  Both mistakes are expensive and opposite. Deleting too little leaves bot
#       mandants and other people's addresses lying around; deleting too eagerly
#       destroys a real customer's organisation. Every guard that says "do not
#       delete this one" is pinned individually, because a guard that silently
#       stops matching looks exactly like a guard that is doing its job.
RSpec.describe UnconfirmedSignupPurgeJob, type: :job do
  # The job re-reads every candidate on purpose (the confirmed_at race guard in
  # purgeable?) and walks each organisation's guards one by one; with more than
  # one candidate Prosopite reports that deliberate per-row work as an N+1.
  before { Prosopite.pause }

  def stub_env(**values)
    allow(ENV).to receive(:[]).and_call_original
    values.each { |name, value| allow(ENV).to receive(:[]).with(name.to_s).and_return(value) }
  end

  def arm!
    stub_env(described_class::ENFORCE_ENV.to_sym => '1')
  end

  # A registration as the controller leaves it: unconfirmed user, own
  # organisation, sole membership.
  def stale_signup(created_at: (described_class::RETENTION + 1.day).ago, confirmed_at: nil)
    user = create(:user, confirmed_at: confirmed_at)
    organisation = create(:organisation)
    # Created under the tenant like production writes are; the job itself runs
    # without one and opens a tenant per organisation only for the untouched?
    # reads (Membership itself is not tenant-scoped).
    ActsAsTenant.with_tenant(organisation) { create(:membership, user: user, organisation: organisation) }
    user.update_columns(created_at: created_at, confirmed_at: confirmed_at)
    [user, organisation]
  end

  describe 'the dry run it ships as' do
    it 'deletes nothing without the ENV switch, however stale the signup' do
      user, = stale_signup

      described_class.perform_now

      expect(user.reload.deleted_at).to be_nil
    end

    # The log is the only output of a dry run. Without this the first production
    # runs would be indistinguishable from a job that matches nothing at all.
    it 'names what it would delete' do
      allow(Rails.logger).to receive(:info)
      user, = stale_signup

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(a_string_matching(/would erase user=#{user.id}/))
    end
  end

  describe 'when armed' do
    before { arm! }

    it 'erases the user, name and address included' do
      user, = stale_signup

      described_class.perform_now

      user.reload
      expect(user.deleted_at).to be_present
      expect(user.email).not_to include('@example')
    end

    # The organisation is left ON PURPOSE, and the membership is not: erasing
    # the user empties the organisation so nobody can enter it, while destroying
    # it is impossible today (user_activities holds a foreign key to
    # organisations with no cascade). If this ever starts destroying the
    # organisation, it does so unproven -- hence the pin.
    it 'empties the organisation but leaves it and its account standing' do
      user, organisation = stale_signup
      account = create(:account)
      organisation.update_column(:account_id, account.id)

      described_class.perform_now

      expect(Organisation.exists?(organisation.id)).to be(true)
      expect(Account.exists?(account.id)).to be(true)
      expect(organisation.reload.memberships.where(user_id: user.id)).to be_empty
    end

    # The abandoned rows are the price of the scope above, so the run has to say
    # how many it left -- otherwise nobody can size the follow-up.
    it 'reports how much it left behind' do
      allow(Rails.logger).to receive(:info)
      stale_signup

      described_class.perform_now

      expect(Rails.logger).to have_received(:info)
        .with(a_string_matching(/erased=1 skipped=0 scanned=1 capped=false scan_capped=false abandoned_organisations=1/))
    end

    it 'keeps a signup that is younger than the retention' do
      user, = stale_signup(created_at: (described_class::RETENTION - 1.day).ago)

      described_class.perform_now

      expect(user.reload.deleted_at).to be_nil
    end

    # The boundary in both directions, so the retention cannot drift unnoticed.
    it 'keeps a signup exactly at the retention and takes the one just past it' do
      at_boundary, = stale_signup(created_at: described_class::RETENTION.ago + 1.minute)
      past_boundary, = stale_signup(created_at: described_class::RETENTION.ago - 1.minute)

      described_class.perform_now

      expect(at_boundary.reload.deleted_at).to be_nil
      expect(past_boundary.reload.deleted_at).to be_present
    end

    it 'keeps a confirmed account of any age' do
      user, = stale_signup(confirmed_at: 1.year.ago)

      described_class.perform_now

      expect(user.reload.deleted_at).to be_nil
    end

    it 'keeps an invited user, whose unconfirmed state is an anomaly and not junk' do
      user, organisation = stale_signup
      user.update_column(:invited_by_org_id, organisation.id)

      described_class.perform_now

      expect(user.reload.deleted_at).to be_nil
      expect(Organisation.exists?(organisation.id)).to be(true)
    end

    it 'keeps an organisation that has a second member' do
      user, organisation = stale_signup
      ActsAsTenant.with_tenant(organisation) { create(:membership, user: create(:user), organisation: organisation) }

      described_class.perform_now

      expect(user.reload.deleted_at).to be_nil
      expect(Organisation.exists?(organisation.id)).to be(true)
    end

    # Somebody worked here. A project without system_kind was made by a human,
    # never by the onboarding seed.
    it 'keeps an organisation that holds a project of its own' do
      user, organisation = stale_signup
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }

      described_class.perform_now

      expect(user.reload.deleted_at).to be_nil
      expect(Organisation.exists?(organisation.id)).to be(true)
    end

    # organisations.all? over solo?/untouched?: a user in two organisations
    # where the SECOND holds real work must be kept whole. Without this the
    # all?->any? mutation (erase if ANY org is disposable) stays green, and it
    # would anonymise a user who has real work in a colleague-less side org.
    it 'keeps a user whose second organisation holds real work' do
      user, = stale_signup
      other = create(:organisation)
      ActsAsTenant.with_tenant(other) do
        create(:membership, user: user, organisation: other)
        create(:project, organisation: other)
      end

      described_class.perform_now

      expect(user.reload.deleted_at).to be_nil
      expect(Organisation.exists?(other.id)).to be(true)
    end

    it 'erases a user whose only project is the seeded tutorial' do
      user, organisation = stale_signup
      ActsAsTenant.with_tenant(organisation) do
        create(:project, organisation: organisation, system_kind: 'onboarding')
      end

      described_class.perform_now

      expect(user.reload.deleted_at).to be_present
    end

    # The header above promises every guard its own pin; documents, time
    # sessions, chats and meetings were the unpinned four. Each record is
    # placed INSIDE the seeded tutorial project, so the projects guard cannot
    # be the reason the user survives -- only the guard under test is. A chat
    # has no project since the project chat went (#666); its scope is the
    # nearest link it still has.
    { document: :project, time_session: :project, chat: :scope_project, meeting: :project }.each do |trace, link|
      it "keeps an organisation where somebody created a #{trace.to_s.humanize.downcase}" do
        user, organisation = stale_signup
        ActsAsTenant.with_tenant(organisation) do
          tutorial = create(:project, organisation: organisation, system_kind: 'onboarding')
          create(trace, organisation: organisation, link => tutorial)
        end

        described_class.perform_now

        expect(user.reload.deleted_at).to be_nil
      end
    end

    # The presence heartbeat stamps last_seen_at on every authenticated
    # request; presence well past the signup means somebody WORKED here --
    # including work inside the seeded tutorial project, which none of the
    # untouched? checks can see.
    it 'keeps a user who was still around an hour after signing up' do
      user, = stale_signup
      user.update_columns(last_seen_at: user.created_at + described_class::PRESENCE_KEEP_WINDOW + 1.minute)

      described_class.perform_now

      expect(user.reload.deleted_at).to be_nil
    end

    # The redirect right after signup already stamps last_seen_at once, so bare
    # presence must NOT protect -- otherwise every abandoned browser signup
    # would live forever, against the privacy statement's 14-day promise.
    it 'still erases a user whose only presence is the signup itself' do
      user, = stale_signup
      user.update_columns(last_seen_at: user.created_at + 10.seconds)

      described_class.perform_now

      expect(user.reload.deleted_at).to be_present
    end

    # Vacuous truth, pinned as intended: no organisation at all (what the
    # organisation_creation_failed path leaves behind) is junk by definition.
    it 'erases a stale signup that has no organisation at all' do
      user = create(:user, confirmed_at: nil)
      user.update_columns(created_at: (described_class::RETENTION + 1.day).ago, confirmed_at: nil)

      described_class.perform_now

      expect(user.reload.deleted_at).to be_present
    end

    # User.system has no memberships, so the organisations.all? walk is
    # vacuously true and ONLY the explicit guard keeps it alive.
    it 'keeps the system account even when it looks stale and unconfirmed' do
      system_user = User.system
      system_user.update_columns(created_at: 1.year.ago, confirmed_at: nil)

      described_class.perform_now

      expect(system_user.reload.deleted_at).to be_nil
    end

    # The race the reload guard exists for: a confirmation click landing after
    # the candidate query already collected the user. Simulated by feeding the
    # job a relation that ignores confirmed_at, exactly like a stale batch.
    it 'keeps a user who confirmed while the run was in flight' do
      user, = stale_signup
      allow_any_instance_of(described_class).to receive(:candidates)
        .and_return(User.where(id: user.id))
      user.update_column(:confirmed_at, Time.current)

      described_class.perform_now

      expect(user.reload.deleted_at).to be_nil
    end

    # The SECOND confirm-race window: a confirmation landing AFTER purgeable? read
    # the row but BEFORE the deletion. purgeable? is forced past its own reload
    # guard so that only erase's under-lock confirmed_at re-check can save the
    # user -- the mutation that drops that re-check anonymises a just-confirmed
    # real account, and stays green without this.
    it 'keeps a user confirmed between the guard checks and the deletion' do
      user, = stale_signup
      allow_any_instance_of(described_class).to receive(:purgeable?).and_return(true)
      user.update_column(:confirmed_at, Time.current)

      described_class.perform_now

      expect(user.reload.deleted_at).to be_nil
    end

    # A redeemable invitation means somebody can still join this org; erasing the
    # lone inviter would empty and rename it, stranding the invitee in a husk.
    it 'keeps an organisation that has a redeemable invitation waiting' do
      user, organisation = stale_signup
      ActsAsTenant.with_tenant(organisation) do
        create(:invitation, organisation: organisation, sent_at: 1.day.ago)
      end

      described_class.perform_now

      expect(user.reload.deleted_at).to be_nil
      expect(Organisation.exists?(organisation.id)).to be(true)
    end

    # An ACCEPTED invitation is not redeemable (it has become a membership,
    # covered by solo?), so it must NOT by itself keep an otherwise-disposable
    # org alive.
    it 'still erases despite an already-accepted invitation' do
      user, organisation = stale_signup
      ActsAsTenant.with_tenant(organisation) do
        create(:invitation, organisation: organisation, accepted_at: Time.current)
      end

      described_class.perform_now

      expect(user.reload.deleted_at).to be_present
    end

    # An EXPIRED, never-accepted invitation can never be redeemed, so it must not
    # keep the junk org alive -- otherwise it becomes a permanent skip that the
    # run re-walks forever. sent_at past the invitation TTL makes it un-redeemable.
    it 'still erases despite an expired unaccepted invitation' do
      user, organisation = stale_signup
      ActsAsTenant.with_tenant(organisation) do
        create(:invitation, organisation: organisation, sent_at: (Invitation::VALIDITY + 1.day).ago)
      end

      described_class.perform_now

      expect(user.reload.deleted_at).to be_present
    end

    # One failing candidate must not take the rest of the run down with it.
    it 'logs a failure and carries on with the next candidate' do
      failing, = stale_signup
      healthy, = stale_signup
      allow(Rails.logger).to receive(:error)
      allow_any_instance_of(User).to receive(:soft_delete_and_anonymize!) do |user|
        raise ActiveRecord::InvalidForeignKey, 'boom' if user.id == failing.id

        user.update_columns(deleted_at: Time.current)
      end

      described_class.perform_now

      expect(failing.reload.deleted_at).to be_nil
      expect(healthy.reload.deleted_at).to be_present
      expect(Rails.logger).to have_received(:error).with(a_string_matching(/user=#{failing.id}/))
    end

    # untouched? reads Document/TimeSession/Chat/Meeting UNQUALIFIED, correct
    # only inside the with_tenant block. Every other example puts the trace in
    # the candidate's OWN org, so dropping the wrapper stays green; in production
    # those tables are never globally empty, so the mutated job would skip every
    # candidate forever. Here an unrelated org holds the work and the candidate's
    # own org is clean -- the candidate must still be erased.
    it 'still erases a candidate when only an unrelated organisation holds work' do
      user, = stale_signup
      other = create(:organisation)
      ActsAsTenant.with_tenant(other) do
        tutorial = create(:project, organisation: other, system_kind: 'onboarding')
        create(:membership, user: create(:user), organisation: other)
        create(:document, organisation: other, project: tutorial)
        create(:chat, organisation: other)
      end

      described_class.perform_now

      expect(user.reload.deleted_at).to be_present
    end

    # candidates filters deleted_at: nil. Without it the job would re-anonymise
    # every previously purged user each night and inflate the erased counter the
    # dry-run decision is read from. This is the only candidate, so nothing
    # legitimate should be soft-deleted here.
    it 'never touches an already soft-deleted signup' do
      user, = stale_signup
      user.update_columns(deleted_at: 1.day.ago)

      expect_any_instance_of(described_class).not_to receive(:erase)

      described_class.perform_now
    end

    # The abandoned org's name is derived from the signup email; erase must strip
    # it, or a fragment of the never-confirmed address lingers in
    # organisations.name after the "deletion".
    it 'strips the email-derived name off the abandoned organisation' do
      user, organisation = stale_signup
      organisation.update_column(:name, "otto's Organisation")

      described_class.perform_now

      expect(user.reload.deleted_at).to be_present
      expect(organisation.reload.name).not_to include('otto')
      expect(organisation.name).to include(organisation.id)
    end

    # AccountAutoAssignable copies the email-derived org name onto accounts.name
    # at create, so the wipe has to strip it there too -- otherwise the local part
    # of the never-confirmed address lingers on a live record the abandoned-account
    # log deliberately points at.
    it 'strips the email-derived name off the abandoned account too' do
      user, organisation = stale_signup
      account = create(:account, name: "otto's Organisation")
      organisation.update_columns(account_id: account.id, name: "otto's Organisation")

      described_class.perform_now

      expect(user.reload.deleted_at).to be_present
      expect(account.reload.name).not_to include('otto')
    end

    # MAX_PER_RUN bounds one nightly run so a bot wave cannot make it arbitrarily
    # long on a shared queue; the overflow is logged and waits for tomorrow.
    it 'stops at MAX_PER_RUN and records that it capped' do
      stub_const("#{described_class}::MAX_PER_RUN", 1)
      first, = stale_signup
      second, = stale_signup
      allow(Rails.logger).to receive(:info)

      described_class.perform_now

      expect(Rails.logger).to have_received(:info).with(a_string_matching(/capped=true/))
      # The overflow candidate must actually SURVIVE to tomorrow: without this a
      # mutation that logs capped=true but drops the break erases both and stays
      # green. Exactly one of the two was erased (default_scope hides soft-deleted
      # rows, so reload each explicitly rather than counting on the class).
      erased = [first, second].count { |u| u.reload.deleted_at.present? }
      expect(erased).to eq(1)
    end

    # The cap counts ERASED, not skipped: a permanently-unpurgeable candidate
    # ahead of real junk must not consume the budget, or a handful of them would
    # starve the run forever. Here the only over-budget candidate is erasable, so
    # a non-erasable one sitting in the set does not stop it being reached.
    it 'does not let a skipped candidate consume the per-run budget' do
      stub_const("#{described_class}::MAX_PER_RUN", 1)
      # A kept candidate (second member) plus a disposable one.
      kept, kept_org = stale_signup
      ActsAsTenant.with_tenant(kept_org) { create(:membership, user: create(:user), organisation: kept_org) }
      junk, = stale_signup

      described_class.perform_now

      expect(kept.reload.deleted_at).to be_nil
      expect(junk.reload.deleted_at).to be_present
    end

    # The read-work backstop: since skips no longer count against MAX_PER_RUN, a
    # pathological pile of kept candidates could otherwise make one run examine
    # them all. MAX_SCAN_PER_RUN bounds candidates EXAMINED and says so loudly --
    # a silent stop here would read as "nothing left to do" when the tail was
    # never seen.
    it 'stops at MAX_SCAN_PER_RUN and warns that the tail went unseen' do
      stub_const("#{described_class}::MAX_SCAN_PER_RUN", 1)
      2.times { stale_signup }
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now

      expect(Rails.logger).to have_received(:warn).with(a_string_matching(/scan ceiling hit/))
    end
  end

  # The arming switch is a cast, not a bare presence check: ENV set to the STRING
  # "false" or "0" (the obvious way to turn it OFF) must stay a dry run. Without
  # the cast, ENFORCE=false would arm an irreversible anonymisation.
  describe 'the arming cast' do
    %w[false 0].each do |off|
      it "treats ENFORCE=#{off.inspect} as a dry run and deletes nothing" do
        user, = stale_signup
        stub_env(described_class::ENFORCE_ENV.to_sym => off)

        described_class.perform_now

        expect(user.reload.deleted_at).to be_nil
      end
    end
  end
end
