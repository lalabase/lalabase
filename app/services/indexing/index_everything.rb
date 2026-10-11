# frozen_string_literal: true

# The one-off for the stock after doc/notizen_immer_indexiert_plan.md: notes and
# document versions are indexed by default since 10.09.2026, like tickets. Every
# row still opted out is flipped, and every row never indexed (flag nil) gets the
# same job a save enqueues, per organisation whose embedding lane is usable.
# Idempotent: EmbeddingProcessingService skips what is already embedded. Metered
# like a save is (one AiUsage row per record); the operator decides per
# organisation whether to run it (rake indexing:everything).
# Entry point: Indexing::IndexEverything.call(organisation:)
module Indexing
  class IndexEverything
    Result = Struct.new(:flipped, :enqueued, :reason, keyword_init: true)

    # The tables that lost their switch, each with the association its fragments
    # hang off (the job's fragment_association).
    TARGETS = { Note => :fragments, DocumentVersion => :fragments }.freeze

    def self.call(organisation:)
      new(organisation: organisation).call
    end

    def initialize(organisation:)
      @organisation = organisation
    end

    def call
      pending = {}
      flipped = 0

      ActsAsTenant.with_tenant(@organisation) do
        TARGETS.each_key do |klass|
          scope = klass.where(organisation_id: @organisation.id)
          # NULL is opted out as well: the document actors used to assign nil
          # whenever the form hid the switch (review of #778, P2). And a flipped
          # row becomes PENDING again (completion flag nil): a row indexed once,
          # then edited while opted out, keeps its old completion flag over purged
          # fragments, and a run that could enqueue nothing (no usable lane) would
          # otherwise leave it invisible to every later run.
          opted_out_ids = scope.where(create_embeddings: [nil, false]).pluck(:id)
          flipped += flip(scope, opted_out_ids)
          never_indexed_ids = scope.where(embeddings_creation_flag: nil).pluck(:id)
          pending[klass] = (opted_out_ids + never_indexed_ids).uniq
        end
      end

      availability = @organisation.ai_available_for?(:content_indexing)
      return refused(flipped, availability) unless availability&.available?

      enqueued = 0
      TARGETS.each do |klass, association|
        pending.fetch(klass, []).each do |id|
          EmbeddingProcessingJob.perform_later(record_class: klass, record_id: id, fragment_association: association)
          enqueued += 1
        end
      end

      Result.new(flipped: flipped, enqueued: enqueued, reason: nil)
    end

    private

    # Opted in AND pending again, in one statement (no callbacks: a flip is not an edit).
    def flip(scope, ids)
      return 0 if ids.empty?

      scope.where(id: ids).update_all(create_embeddings: true, embeddings_creation_flag: nil)
    end

    # The flag is flipped either way; a job that could only fail is not enqueued.
    def refused(flipped, availability)
      Result.new(flipped: flipped, enqueued: 0, reason: availability&.reason || :ai_disabled)
    end
  end
end
