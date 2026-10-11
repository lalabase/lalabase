# frozen_string_literal: true

# app/services/actors/flip_embedding_model.rb
#
# Switches which vector space serves an organisation's retrieval — THE flip of the
# staged switch (embedding v2 PR 6a, doc/embedding_v2_pr6_retention_plan.md §4.4).
#
# The write itself is one column on one row. Everything else here is the refusal:
# a flip onto an incomplete target space would leave part of the corpus unreachable,
# and unreachable content in this subsystem does not raise — it returns zero hits.
#
# Domain failures use precise codes: :foreign_space / :already_active /
# :incomplete_target.

module Actors
  class FlipEmbeddingModel < BaseActor
    ERROR_SCOPE = 'services.actors.flip_embedding_model'

    # @param organisation [Organisation] whose pointer moves
    # @param target_space [EmbeddingSpace] the space that should serve from now on
    def initialize(organisation:, target_space:, current_user:)
      super()
      @organisation = organisation
      @target_space = target_space
      @current_user = current_user
    end

    def record
      @organisation
    end

    def perform
      reject!(:foreign_space) unless @target_space.organisation_id == @organisation.id

      incomplete = incomplete_targets
      # Two states look identical through the readable-row anti-join but need OPPOSITE
      # repairs, and confusing them costs an operator the incident: a space that is
      # genuinely missing rows needs a build, a merely RETIRED one needs reactivation.
      # Telling "build the target space" during a roll-back would send them to build the
      # space they are trying to leave (review finding F2).
      if incomplete.any?
        # The ids travel INTO the message: the retired-space repair is
        # `embeddings:rollback[ORG,SPACE]`, and both values are known right here. Printing
        # placeholders would make the operator look up an id mid-incident (review A-2).
        reject!(retired_target? ? :retired_target : :incomplete_target,
                missing: format_missing(incomplete),
                organisation_id: @organisation.id, space_id: @target_space.id)
      end

      move_pointer
    end

    def enqueue_jobs
      # Nothing to retire on an org's FIRST flip (no previous space).
      return if @previous_space_id.blank?

      enqueue_after_commit do
        Embeddings::RetireSpaceJob.perform_later(@organisation.id, @previous_space_id)
      end
    end

    private

    # Decide and write with the organisation row LOCKED, and read the pointer FRESH
    # inside that lock (review finding R5). Reading @organisation.active_embedding_space_id
    # from the in-memory instance — which is what this did until 6b — is a
    # time-of-check/time-of-use gap: two concurrent flips (or one stale instance) both
    # see the same predecessor, so the space that was ACTUALLY displaced is never
    # retired and stays in the ANN indexes forever. Index weight, not a wrong answer —
    # readers keep filtering on the active space — but it also breaks the retention
    # GC's ordering, which asks exactly this question ("which space stopped serving,
    # and when").
    #
    # BaseActor#call already opened the transaction; the expensive anti-joins above run
    # OUTSIDE the lock on purpose, so a flip holds the row for one UPDATE, not for a
    # corpus scan. Same shape as Embeddings::RetireSpaceJob#retire_unless_active, which
    # takes this lock from the other side.
    def move_pointer
      locked = Organisation.lock.find_by(id: @organisation.id)
      # The org was deleted while the anti-joins ran — nothing left to point anywhere.
      # Its own code (review): reusing :foreign_space here told the operator "belongs
      # to a different organisation" about an org that simply no longer exists.
      reject!(:organisation_gone) if locked.nil?
      # Authoritative check, deliberately NOT duplicated as a cheap pre-check above:
      # only the locked read can tell a genuine no-op from a race that a pre-check
      # would wave through.
      reject!(:already_active) if locked.active_embedding_space_id == @target_space.id

      @previous_space_id = locked.active_embedding_space_id
      # THE flip: one column, one UPDATE, no callbacks, no dependent writes.
      #
      # update_column, not update!: this must not run the org's validations (an
      # unrelated validation error elsewhere on the record would make the org
      # unflippable, i.e. unable to leave a broken space) and must not fire callbacks.
      # It is a pointer move, not a state change of the organisation.
      locked.update_column(:active_embedding_space_id, @target_space.id)
      # Keep the caller's instance in step — the rake task and the 6b/6c callers read
      # it back after a successful flip.
      @organisation.reload if @organisation.persisted?
      stamp_retirement
    end

    # `retired_at` answers "when did this space last STOP serving" — the ordering the
    # retention GC keeps its spaces by (sheet §4.2). It is written HERE, under the same
    # lock as the pointer, because this is the only moment the answer is known: the
    # displaced space gets a timestamp, the incoming one gets NULL back (it serves
    # again, so it is no longer a retired space that may be collected).
    #
    # NULL therefore means "never served" — a build abandoned before its flip. Those
    # sort last and are collected first, which is right: they are no roll-back target.
    #
    # with_tenant(@organisation), and the relation built INSIDE it (review C1): the
    # relation evaluates acts_as_tenant's default scope the moment it is BUILT, and
    # require_tenant is on — built outside any tenant lift, this raised NoTenantSet on
    # the tenant-less `rake embeddings:flip` path (the specs never saw it because the
    # suite sets an ambient tenant). with_tenant rather than without_tenant, matching
    # EnsureSpace/RetireSpaceJob next door: it is also correct under a FOREIGN ambient
    # tenant (a 6c admin flipping org X), where without_tenant-with-outside-relation
    # would have scoped the update to the wrong org and silently stamped nothing.
    def stamp_retirement
      ActsAsTenant.with_tenant(@organisation) do
        spaces = ::EmbeddingSpace.where(organisation_id: @organisation.id)
        spaces.where(id: @target_space.id).update_all(retired_at: nil)
        spaces.where(id: @previous_space_id).update_all(retired_at: Time.current) if @previous_space_id.present?
      end
    end

    # Completeness as an ANTI-JOIN, never as a count (M3, series plan §5.3 step 3):
    # "target rows >= records" is gamed by orphaned sidecar rows — rows whose record is
    # gone still count, so a half-built space can present matching totals. The anti-join
    # asks the only question that matters, "is there a source record with no readable
    # row in the target space", and an orphan cannot answer it.
    #
    # Reuses Embeddings::OrganisationReindexer.missing_in_space rather than restating
    # the predicate: the reindexer's skip logic, this validation and `embeddings:status`
    # must agree with the read seam forever, and three hand-written copies is how that
    # stops being true.
    #
    # @return [Hash{String => Integer}] model => missing count, zero entries removed
    def incomplete_targets
      ActsAsTenant.with_tenant(@organisation) do
        Embeddings::OrganisationReindexer
          .missing_in_space(organisation: @organisation, space: @target_space.triple)
          .reject { |_model, count| count.zero? }
      end
    end

    # True when the target space holds a row for EVERY record and the only thing missing
    # is `indexed` — i.e. the space was retired after an earlier flip, not left half
    # built. Reactivation (Embeddings::SpaceIndexFlag) fixes this; a build does not.
    # The roll-back task performs the reactivation itself; this branch exists for the
    # operator who flips by hand.
    def retired_target?
      ActsAsTenant.with_tenant(@organisation) do
        Embeddings::OrganisationReindexer
          .missing_in_space(organisation: @organisation, space: @target_space.triple,
                            require_indexed: false)
          .values.all?(&:zero?)
      end
    end

    def format_missing(incomplete)
      incomplete.map { |model, count| "#{model}=#{count}" }.join(' ')
    end

    def reject!(code, **interpolations)
      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.#{code}", **interpolations), code: code)
    end
  end
end
