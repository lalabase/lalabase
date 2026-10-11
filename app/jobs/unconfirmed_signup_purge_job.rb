# frozen_string_literal: true

# Erases self-registrations that never proved their address
# (doc/bot_registrierungen_plan.md S4).
#
# WHY IT EXISTS: an automated signup writes a user, an organisation, an account,
# a role, a membership and the onboarding tutorial. The bot trap and the
# throttles stop most of that at the door; whatever gets through stays forever,
# and every one of those rows carries an e-mail address belonging to somebody
# who never asked for an account here.
#
# SHIPS AS A DRY RUN. Same rule as the embedding GC: the first production runs
# only log what they WOULD erase, and deletion is armed with an ENV switch on the
# worker once that log has been read. A job that starts deleting on the day it
# deploys is a job nobody gets to verify first.
#
# SCOPE: THE USER, NOT THE ORGANISATION. Deleting an organisation is not
# possible in this app today and this job does not invent it: user_activities
# holds a plain foreign key to organisations with no cascade and no dependent
# option, so an organisation that anybody has ever acted in cannot be destroyed
# (measured -- the destroy raises InvalidForeignKey). The same is true of the
# Account, whose seat stream is the billing record. What is left behind is
# inert: erasing the user destroys their memberships, so the organisation has no
# members and nobody can enter it. Its NAME, though, is derived from the signup
# email ("<local-part>'s Organisation") and AccountAutoAssignable copies that
# name onto the account, so the erase step overwrites BOTH organisations.name and
# accounts.name with a neutral placeholder -- otherwise a fragment of the
# never-confirmed address would sit on a live record forever. Residual
# (accepted): SeatEvent carries a frozen copy of the org name and is append-only,
# so historic seat rows keep the old name; the live records are what a person or
# an export reads.
# The abandoned organisations and accounts are LOGGED per run, so the follow-up
# decision has a number to work from instead of an estimate.
class UnconfirmedSignupPurgeJob < ApplicationJob
  queue_as :default

  # Devise refuses the login after confirm_within (7 days), so 14 days is twice
  # the window in which the address could still have been proven.
  RETENTION = 14.days

  ENFORCE_ENV = 'UNCONFIRMED_SIGNUP_PURGE_ENFORCE'

  # Presence past this offset after registration means somebody WORKED here.
  # The heartbeat (User::Presence) stamps last_seen_at on every authenticated
  # request, and the redirect right after signup already produces one — bare
  # presence therefore proves nothing, presence well past the signup does.
  # This guards what untouched? cannot see: tickets and comments written
  # inside the seeded tutorial project leave no trace in any of its checks.
  #
  # RESIDUAL GAP (accepted): last_seen_at only tracks BROWSER presence
  # (User::Presence excludes API/token usage) and needs work to span the hour.
  # A user who works intensively for <1h and never returns, or drives the app
  # only through a personal access token, trips neither this guard nor
  # untouched? and would be erased with their tutorial-project content. Low
  # probability against the "junk gets removed" goal; widen the window or add a
  # ticket-author check if the dry-run log ever shows a real account lost.
  PRESENCE_KEEP_WINDOW = 1.hour

  # A per-run ceiling on ERASURES. This job walks each candidate one by one on
  # purpose (the confirmed_at re-read, five tenant-scoped guard reads, a
  # soft-delete transaction), so a genuine bot wave -- the exact event this
  # feature exists for -- could otherwise make one nightly run arbitrarily long
  # on a queue it shares with the deletion, rollup and seat jobs. What overflows
  # is logged and simply waits for tomorrow's run.
  MAX_PER_RUN = 500

  # A per-run ceiling on candidates EXAMINED, the backstop for read work. The
  # erase cap alone does not bound a run: a candidate that can never be purged
  # (an org holding real work, a colleague, a redeemable invitation) is not
  # erased, so it does not count against MAX_PER_RUN, yet each one still costs a
  # reload plus the tenant-scoped guard reads on every future run. Cheap
  # always-permanent skips (invited, present past the window) are dropped in SQL
  # (see #candidates); this bounds the read cost of the rest. Reaching it is
  # abnormal -- it means more kept-but-unconfirmed accounts than a real instance
  # accumulates -- so it is logged LOUDLY rather than passing silently.
  MAX_SCAN_PER_RUN = 5_000

  # Neutral, PII-free, and unique per organisation so the instance-wide name
  # uniqueness holds. See the SCOPE note in the class header.
  def self.neutral_org_name(organisation)
    "Entfernte Registrierung #{organisation.id}"
  end

  def perform
    erased = 0
    skipped = 0
    scanned = 0
    capped = false
    scan_capped = false
    abandoned_organisations = []
    abandoned_accounts = []

    # The reads in untouched? (projects, documents, time sessions, chats,
    # meetings) are tenant-scoped and this job has no ambient tenant; the
    # organisations are preloaded so the guards below do not re-query per user.
    ActsAsTenant.without_tenant do
      candidates.includes(:organisations).find_each do |user|
        # Cap on ERASED, not on erased+skipped. A skipped candidate that can never
        # be purged (an org that holds real work, a redeemable invitation) stays
        # in the candidate set and, walked in stable primary-key order, would
        # consume the budget on every future run -- a handful of permanent skips
        # ahead of real junk could starve the run forever, logging capped=true
        # while erasing nothing. The cheap, always-permanent skips (invited, still
        # present past the window) are already excluded in SQL (see #candidates);
        # the rest no longer counts against the erase ceiling.
        if erased >= MAX_PER_RUN
          capped = true
          break
        end

        # ...but the erase cap alone leaves read work unbounded (see
        # MAX_SCAN_PER_RUN): permanent skips are re-examined every run. This second
        # ceiling bounds that, and is logged loudly because reaching it is abnormal.
        if scanned >= MAX_SCAN_PER_RUN
          scan_capped = true
          break
        end
        scanned += 1

        organisations = user.organisations.to_a

        unless purgeable?(user, organisations)
          skipped += 1
          next
        end

        # erase returns false when its own under-lock confirmed_at re-check bails
        # (a confirmation that landed after purgeable? read the row) -- that is a
        # skip, not an erase.
        unless erase(user, organisations)
          skipped += 1
          next
        end

        erased += 1
        abandoned_organisations.concat(organisations.map(&:id))
        abandoned_accounts.concat(organisations.filter_map(&:account_id))
      rescue StandardError => e
        skipped += 1
        Rails.logger.error("[UnconfirmedSignupPurge] user=#{user.id} failed: #{e.class}: #{e.message}")
      end
    end

    Rails.logger.info(
      "[UnconfirmedSignupPurge] mode=#{enforce? ? 'enforce' : 'dry-run'} " \
      "#{enforce? ? 'erased' : 'would_erase'}=#{erased} skipped=#{skipped} scanned=#{scanned} " \
      "capped=#{capped} scan_capped=#{scan_capped} " \
      "abandoned_organisations=#{abandoned_organisations.uniq.size} " \
      "abandoned_accounts=#{abandoned_accounts.uniq.size}"
    )

    # Loud, separate line so the abnormal case cannot hide inside the routine
    # summary: more kept-but-unconfirmed accounts than one run examines means the
    # tail went unseen this run and something upstream is worth a look.
    return unless scan_capped

    Rails.logger.warn(
      "[UnconfirmedSignupPurge] scan ceiling hit: examined #{scanned} candidates " \
      "(MAX_SCAN_PER_RUN=#{MAX_SCAN_PER_RUN}); remaining candidates were not seen this run"
    )
  end

  private

  def candidates
    # The cheap, ALWAYS-permanent skip reasons are filtered here rather than in
    # purgeable?, so they never enter the candidate set and never consume
    # MAX_PER_RUN (see the cap note in #perform). An invited user's unconfirmed
    # state never becomes purgeable, and last_seen_at only grows, so a user
    # already present past the window can never become purgeable either --
    # excluding both in SQL is safe. The matching Ruby guards in purgeable? stay
    # as defence in depth. system_account? stays in Ruby (one row, not worth
    # coupling this query to the account's email constant).
    User.where(confirmed_at: nil, deleted_at: nil)
        .where(invited_by_org_id: nil)
        .where(created_at: ...RETENTION.ago)
        .where('users.last_seen_at IS NULL OR users.last_seen_at <= users.created_at + make_interval(secs => ?)',
               PRESENCE_KEEP_WINDOW.to_i)
  end

  # Every condition here is a reason NOT to erase. The default answer is no.
  def purgeable?(user, organisations)
    # Re-read the row first: a confirmation click can land between the candidate
    # query and this batch reaching the user. Resending the mail restarts the
    # 7-day window, so a confirmation on day 13 is a supported flow, not a
    # theoretical race.
    return false if user.reload.confirmed_at.present?
    return false if user.system_account?
    # Invited people are somebody else's colleague, not a self-registration --
    # and the invitation path skips confirmation, so an unconfirmed invited user
    # is an anomaly to look at, not junk to remove.
    return false if user.invited_by_org_id.present?
    return false if lingered?(user)

    # An empty organisations list passes vacuously, ON PURPOSE: a user without
    # any organisation is what the organisation_creation_failed path leaves
    # behind, and it is junk by definition.
    organisations.all? do |organisation|
      solo?(organisation, user) && no_redeemable_invitations?(organisation) && untouched?(organisation)
    end
  end

  # A REDEEMABLE invitation means somebody can still join this org. Erasing the
  # lone inviter empties and renames the org, stranding that invitation in a husk
  # the invitee would land in. Only redeemable ones count: an accepted invitation
  # is already a membership (covered by solo?), and an EXPIRED unaccepted one can
  # never be redeemed -- treating it as "waiting" would make the junk org a
  # permanent skip, the exact accumulation the SQL candidates scope avoids.
  def no_redeemable_invitations?(organisation)
    organisation.invitations.redeemable.none?
  end

  # See PRESENCE_KEEP_WINDOW: stayed (or came back) well past the signup.
  def lingered?(user)
    user.last_seen_at.present? && user.last_seen_at > user.created_at + PRESENCE_KEEP_WINDOW
  end

  # A second member means this is somebody's colleague. Counted on memberships
  # rather than on users so a soft-deleted second account still counts as "not
  # solo" -- erring towards keeping the account.
  def solo?(organisation, user)
    organisation.memberships.where.not(user_id: user.id).none?
  end

  # "Nothing beyond the seeded tutorial." A project without system_kind was made
  # by a human, and documents, time sessions, chats and meetings are never
  # seeded -- any of them means somebody worked here.
  def untouched?(organisation)
    ActsAsTenant.with_tenant(organisation) do
      organisation.projects.where(system_kind: nil).none? &&
        Document.none? && TimeSession.none? && Chat.none? && Meeting.none?
    end
  end

  def erase(user, organisations)
    # The proven erasure path (memberships, exports, meeting analyses,
    # anonymisation, soft delete) instead of a hard DELETE: users are referenced
    # by 52 foreign keys, most without a dependent option, and a hand-rolled
    # delete here would be a second, weaker copy of the deletion rules.
    if enforce?
      # Re-check confirmed_at under a row lock, inside the transaction that does
      # the wipe: purgeable? read confirmed_at before the per-org guard reads, and
      # a confirmation (the supported day-13 resend flow) can still land in that
      # gap. Bailing here returns false so perform counts it as a skip, not an
      # erase. The name neutralisation shares this transaction too, so a crash
      # between the wipe and the rename can no longer leave the email-derived name
      # behind on either the organisation or its account.
      erased_here = false
      user.with_lock do
        if user.confirmed_at.blank?
          user.soft_delete_and_anonymize!
          neutralize_pii(organisations)
          erased_here = true
        end
      end
      return false unless erased_here
    end

    Rails.logger.info(
      "[UnconfirmedSignupPurge] #{enforce? ? 'erased' : 'would erase'} user=#{user.id} " \
      "registered=#{user.created_at.to_date} " \
      "leaves_organisations=#{organisations.map(&:id).join(',')} " \
      "leaves_accounts=#{organisations.filter_map(&:account_id).uniq.join(',')}"
    )
    true
  end

  # Strip the email-derived name off BOTH the organisation and its account:
  # AccountAutoAssignable copies the org name into accounts.name at create, so a
  # rename of the org alone leaves the local part of the never-confirmed address
  # on the account -- a live record an operator and an export both read, which is
  # the same criterion the class header uses to justify renaming the org.
  # update_column: both records are inert now, their validations and callbacks
  # have nothing left to protect and must not block the wipe.
  def neutralize_pii(organisations)
    organisations.each do |organisation|
      neutral = self.class.neutral_org_name(organisation)
      organisation.update_column(:name, neutral)
      organisation.account&.update_column(:name, neutral)
    end
  end

  def enforce?
    ActiveModel::Type::Boolean.new.cast(ENV[ENFORCE_ENV]).present?
  end
end
