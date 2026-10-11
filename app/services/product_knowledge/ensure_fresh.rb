# frozen_string_literal: true

# Brings product_knowledge_entries up to the files before anything reads it.
module ProductKnowledge
  # This is what lets the table work on every installation without a deploy hook
  # (doc/product_knowledge_plan.md, D4): the first read after the files changed notices it and
  # syncs, in production, on a self-hosted install, in development and in a test.
  #
  # The order of the checks is the design, each one cheaper than the next:
  #   1. Memo: this process verified the same file stamp less than MEMO_TTL ago. Nothing to do,
  #      no database access. Building the rows costs about 100 ms (the HTML sanitizer,
  #      measured), so it must not run on every read.
  #   2. The table itself: a fingerprint over its rows equals the one over the source rows.
  #      Compared with the TABLE, not with a stored value, so a truncated, restored or
  #      re-created table is noticed.
  #   3. Never backwards: when the stored generation (the newest change of a help page or
  #      folder at the last sync) is newer than this process's files, this process runs an
  #      older release during a deploy. It reads what is there instead of restoring its older
  #      texts. Deleting a page touches its folder, so a deletion never looks like that.
  #   4. A lock that does not wait. Whoever does not get it reads the table as it is while the
  #      holder syncs. Checked again under the lock: another process may have just finished.
  # All reads skip the query cache: under it, the check under the lock would see the value
  # from before the lock (measured). A source that lacks a language is refused, never synced.
  # An error is reported and the existing rows stay readable; in development and test it
  # raises, as BaseActor does with unexpected errors.
  class EnsureFresh
    GENERATION_KEY = :product_knowledge_generation
    MEMO_TTL = 5.minutes
    # A fixed key in the one database-wide advisory lock space, derived from a name like the
    # other crc32 lock keys in the app. A collision with one of them is unlikely, not impossible.
    LOCK_KEY = Zlib.crc32('product_knowledge_sync')
    BUSY = :busy
    MEMO_MUTEX = Mutex.new

    class << self
      def call(force: false)
        new(force: force).call
      end

      # Specs start every example from a clean slate (spec/support/product_knowledge.rb).
      def forget!
        MEMO_MUTEX.synchronize { @verified = nil }
      end

      def verified?(stamp)
        memo = @verified
        memo.present? && memo[:stamp] == stamp && memo[:at] > MEMO_TTL.ago
      end

      def remember(stamp)
        MEMO_MUTEX.synchronize { @verified = { stamp: stamp, at: Time.current } }
      end
    end

    def initialize(force: false)
      @force = force
    end

    # @return [Sync::Result, nil] what the sync did; nil when nothing was due, the source was
    #   incomplete, another process held the lock, or an error was reported.
    def call
      stamp = Sources.stamp
      return nil if !@force && self.class.verified?(stamp)

      result = ProductKnowledgeEntry.uncached { check_and_sync(stamp) }
      self.class.remember(stamp) unless result == BUSY
      result == BUSY ? nil : result
    rescue StandardError => e
      report(e, stamp)
    end

    private

    def check_and_sync(stamp)
      rows = Sources.rows
      return refuse(rows) unless Sources.complete?(rows)

      target = Sources.fingerprint(Sources.tuples(rows))
      generation = Sources.generation(stamp)
      return nil unless due?(target, generation)

      ProductKnowledgeEntry.transaction(requires_new: true) do
        next BUSY unless lock_acquired?
        next nil unless due?(target, generation)

        sync(rows, generation)
      end
    end

    # The fingerprint decides, and nothing else. There used to be a second
    # condition here, "the generation may not move backwards", and its reason
    # was the deploy: app/docs lived INSIDE a release, so a puma process of the
    # previous one could still be serving and would have written its older texts
    # back over the new ones.
    #
    # The catalogue is one file in shared/, outside every release, so every
    # process sees the same content and that case cannot happen. What the rule
    # still caught were legitimate ones, silently: a restored backup or a rolled
    # back documentation deploy moves the file's mtime backwards, and the
    # assistant would then keep the newer rows forever while the help, which
    # reads the file directly, shows the restored text. The catalogue is the
    # truth; the table follows it in both directions.
    def due?(target, _generation)
      @force || table_fingerprint != target
    end

    def table_fingerprint
      Sources.fingerprint(ProductKnowledgeEntry.pluck(*Sources::KEY_COLUMNS, :content_hash))
    end

    def sync(rows, generation)
      result = Sync.call(rows: rows, rewrite: @force)
      # Kept for diagnosis, not for a decision: it answers "which catalogue is
      # the table built from". Worth a line when it moves backwards, because
      # that means a restore or a rollback happened and somebody may be looking
      # for why the assistant's answers changed.
      previous = SystemSetting.get(GENERATION_KEY).to_i
      if generation.positive? && generation < previous
        Rails.logger.info('ProductKnowledge::EnsureFresh: syncing to an OLDER catalogue ' \
                          "(#{generation} < #{previous}), a restore or a rollback")
      end
      SystemSetting.set(GENERATION_KEY, generation)
      result
    end

    def lock_acquired?
      sql = ProductKnowledgeEntry.sanitize_sql_array(['SELECT pg_try_advisory_xact_lock(?)', LOCK_KEY])
      ActiveModel::Type::Boolean.new.cast(ProductKnowledgeEntry.connection.select_value(sql))
    end

    # Two very different situations, and they were logged the same way until D5.
    #
    # NO language has pages: there is no catalogue at all. That is the NORMAL state of a
    # self-hosted instance and of every development machine (doc/docs_delivery_plan.md), and
    # nothing is broken. It used to log at error, on every read, every five minutes per
    # process, for the whole life of such an instance -- filling the log of an operator who
    # did nothing wrong and burying the errors that matter. Info, once per read.
    #
    # SOME language has pages and another does not: the pair is broken, which is what a
    # half-written deploy looks like. That stays an error, because somebody has to look.
    def refuse(rows)
      missing = Docs::Contract::LOCALES - rows.map { |row| row[:locale] }

      if rows.empty?
        Rails.logger.info('ProductKnowledge::EnsureFresh: no catalogue to read, the table ' \
                          'stays as it is (normal without a documentation deploy)')
      else
        Rails.logger.error("ProductKnowledge::EnsureFresh: no help pages for #{missing.join(', ')}, " \
                           'the table stays as it is')
      end
      nil
    end

    def report(error, stamp)
      raise error if Rails.env.local?

      Rails.logger.error("ProductKnowledge::EnsureFresh: #{error.class}: #{error.message}")
      Rails.error.report(error, handled: true)
      self.class.remember(stamp) if stamp
      nil
    end
  end
end
