# frozen_string_literal: true

# Deletes project threads (assistant plan §5.2, follow-up to the S1 ownership cut).
#
# WHY, and it is not tidiness: until S1 every project thread was readable by every
# project member with the chats area. The ownership backfill (removed with the
# surface, projekt_chat_abbau) (Chats::OwnerBackfill)
# then handed each thread to the author of its FIRST question — which means a thread
# several colleagues had used now belongs to one of them, including their questions.
# A question is never redacted (Neo::Chat::MessageComponent#redacted? decides on the
# citations of a post, and a user post carries none), so those inherited questions are
# readable in full. Deleting the shared-era threads removes the constellation instead
# of guarding it.
#
# Until S4-T1 the sweep took the ticket chat's threads along only on an explicit flag;
# that surface is dissolved, the sweep with the flag was the last act of §13-3, and the
# option went with the column.
#
# Deliberately NOT an Actor, same reasoning the removed ownership backfill had: the actor seam
# carries request writes (Current.user, activity tracking, side-effect jobs). This is an
# operator-run maintenance sweep with no acting user. Tenancy likewise: `without_tenant`
# over the whole estate, because chats are tenant-scoped and an operator sweep is not.
#
# #destroy, never #delete_all: chatposts hang off the chat via `dependent: :destroy`, and
# Chatpost#destroy's guard against deleting a system post deliberately steps aside for a
# parent cascade (`destroyed_by_association`). delete_all would leave 200+ orphan posts
# behind with no foreign key to complain.
module Chats
  class LegacyThreadPurge
    # threads          — threads deleted (dry run: would be deleted)
    # posts            — chatposts that go with them, counted BEFORE the delete
    # per_organisation — {organisation_id => thread count}, so the operator sees whose
    #                    data a run touches before the real run, not after
    Result = Struct.new(:threads, :posts, :per_organisation, keyword_init: true)

    BATCH_SIZE = 500

    # organisation_ids: nil means every organisation. An EMPTY array is not the same
    # thing and is refused below — "no organisations" reaching the sweep as "all of
    # them" is the one misreading that cannot be undone.
    def self.call(dry_run: false, organisation_ids: nil)
      new(dry_run: dry_run, organisation_ids: organisation_ids).call
    end

    def initialize(dry_run: false, organisation_ids: nil)
      raise ArgumentError, 'organisation_ids must not be empty (pass nil for all)' if organisation_ids == []

      @dry_run = dry_run
      @organisation_ids = organisation_ids
    end

    def call
      ActsAsTenant.without_tenant do
        scope = candidates
        # Counted first: after the delete there is nothing left to count, and the dry
        # run must report the same numbers the real run will.
        result = Result.new(
          threads: scope.count,
          posts: Chatpost.where(chat_id: scope.select(:id)).count,
          per_organisation: scope.group(:organisation_id).count
        )
        destroy_in_batches(scope) unless @dry_run
        result
      end
    end

    private

    def destroy_in_batches(scope)
      # Preloaded: the `dependent: :destroy` cascade would otherwise fetch each chat's
      # posts in its own query, which is one round trip per thread on a sweep whose whole
      # point is to run over the estate in one go.
      scope.includes(:chatposts).find_each(batch_size: BATCH_SIZE, &:destroy!)
    end

    # Org-wide threads (project_id NULL, since T3) are NEVER candidates. They do not
    # come from the shared era: since they came into being, the policy guarantees
    # owner = only asker for them (plan §6.3), so the problem this run clears away
    # does not exist there. `where.not(project_id: nil)` is exactly that boundary.
    def candidates
      scope = Chat.where.not(project_id: nil)
      scope = scope.where(organisation_id: @organisation_ids) if @organisation_ids
      scope
    end
  end
end
