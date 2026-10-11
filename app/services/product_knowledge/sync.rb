# frozen_string_literal: true

# Writes Lalabase's own texts into product_knowledge_entries.
module ProductKnowledge
  # Makes the table equal to the given rows: inserts what is new, updates what changed
  # (compared by content_hash), deletes what is gone, including the rows of a source that is
  # no longer registered. Idempotent: a second run over the same rows writes nothing.
  # rewrite: true writes every row whatever its hash says: the repair for a row someone edited
  # by hand without touching the hash.
  #
  # It knows HOW, not WHETHER or WHEN. Callers go through ProductKnowledge::EnsureFresh, which
  # decides, takes the lock and refuses an incomplete source.
  class Sync
    Result = Struct.new(:written, :deleted, keyword_init: true)

    def self.call(rows:, rewrite: false)
      new(rows: rows, rewrite: rewrite).call
    end

    def initialize(rows:, rewrite: false)
      @rows = rows
      @rewrite = rewrite
    end

    def call
      existing = ProductKnowledgeEntry.pluck(:id, :content_hash, *Sources::KEY_COLUMNS)
      written = rows_to_write(existing)
      ProductKnowledgeEntry.upsert_all(written, unique_by: Sources::KEY_COLUMNS) if written.any?
      gone = gone_ids(existing)
      ProductKnowledgeEntry.where(id: gone).delete_all if gone.any?

      Result.new(written: written.size, deleted: gone.size)
    end

    private

    def rows_to_write(existing)
      return @rows if @rewrite

      stored = existing.to_h { |_id, hash, *key| [key, hash] }
      @rows.reject { |row| stored[Sources.key_of(row)] == row[:content_hash] }
    end

    def gone_ids(existing)
      wanted = @rows.to_set { |row| Sources.key_of(row) }
      existing.filter_map { |id, _hash, *key| id unless wanted.include?(key) }
    end
  end
end
