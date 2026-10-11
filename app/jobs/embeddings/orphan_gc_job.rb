# frozen_string_literal: true

module Embeddings
  # Daily GLOBAL orphan sweep (registered in config/recurring.yml — guarded by
  # spec/config/recurring_schedule_spec.rb so it cannot rot into "documented but
  # never runs", the UserDataExportCleanupJob precedent). Runs ONE
  # Embeddings::OrphanGc pass over every org (organisation: nil → without_tenant);
  # per-type isolation lives INSIDE OrphanGc, so one broken type never starves the
  # rest — no per-org loop here anymore.
  #
  # SAFETY GATE (review #354, #3): defaults to DRY-RUN — the daily sweep only LOGS
  # would-reclaim counts until an operator sets EMBEDDINGS_GC_ENFORCE=1. The first
  # prod nights produce numbers to eyeball against `DRY_RUN=1 rake embeddings:gc`
  # before deletes go live.
  #
  # TWO switches, not one (PR 6b, sheet fork F2). The orphan sweeps delete rows whose
  # owner is DB-provably gone — worthless by definition. The retention sweep deletes
  # INTACT vectors of a space an org still holds: the roll-back net. Sharing one switch
  # would mean that the day an operator says "the orphan numbers look right, go ahead"
  # they also, without being asked, arm the deletion of whole vector spaces. Two
  # decisions, two switches; either can be armed on its own.
  class OrphanGcJob < ApplicationJob
    queue_as :default # cheap DB-only work — :indexing is for embedding-API jobs

    # ENV switches that arm real deletion; absent (or anything but '1') = dry-run.
    ENFORCE_ENV = 'EMBEDDINGS_GC_ENFORCE'
    RETENTION_ENFORCE_ENV = 'EMBEDDINGS_RETENTION_ENFORCE'

    def perform
      Embeddings::OrphanGc.call(dry_run: ENV[ENFORCE_ENV] != '1',
                                retention_dry_run: ENV[RETENTION_ENFORCE_ENV] != '1')
    end
  end
end
