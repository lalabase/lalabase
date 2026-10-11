# frozen_string_literal: true

# Lalabase's own texts, read from the catalogue, as rows for product_knowledge_entries.
# Entry point: rows
module ProductKnowledge
  # Which texts go into the table and how each one is read (doc/product_knowledge_plan.md,
  # "Sources"). Since D4 of doc/docs_delivery_plan.md the source is the CATALOGUE another
  # program writes, not this repository's files; this module turns it into the rows
  # ProductKnowledge::Sync writes, and answers the cheap questions EnsureFresh asks first.
  #
  # Fail closed: a source not listed in KEYS is not read, and the sync deletes its rows. The
  # self-hosting docs are deliberately not in here -- they are not in the catalogue at all,
  # because the writer over there builds it from the handbook alone. The news join in S3.
  module Sources
    HELP = 'help'
    KEYS = [HELP].freeze

    # A row's identity: the columns of the unique index, in its order.
    KEY_COLUMNS = %i[source locale slug].freeze
    # Every column the sync writes. content_hash covers all of them, so a change to any one
    # (a renamed section label, a new description, a renderer that strips differently)
    # reaches the table.
    WRITTEN_COLUMNS = %i[source locale slug title section description body_markdown body_text published_on].freeze

    class << self
      # @return [Array<Hash>] one hash per text: WRITTEN_COLUMNS plus content_hash. Unique
      #   by key_of: two files that map to the same slug keep the first, the page the help
      #   itself would open.
      def rows
        help_rows.uniq { |row| key_of(row) }
      end

      # Size and change time of each language's catalogue file (Docs::Catalogue.stamp).
      # Cheap, one stat per language, and equal stamps mean the help has not changed since
      # the last look. A language without a catalogue contributes nil, which is a stamp too:
      # it differs from the one before it lost the file.
      def stamp
        Docs::Contract::LOCALES.map { |locale| Docs::Catalogue.stamp(locale) }
      end

      # The newest change time in a stamp. A deploy of the documentation writes both files,
      # so it moves forward; that is what lets EnsureFresh refuse to sync the table back to an
      # older catalogue. Languages without a file contribute nothing rather than a zero, which
      # would drag the generation backwards and block every later sync.
      def generation(stamp)
        stamp.compact.map(&:last).max.to_i
      end

      # Every language must yield pages. One without any means no catalogue to read, which is
      # the normal state on a self-hosted instance and on a machine that has not fetched one,
      # NOT an empty help: syncing would delete that language's rows and the assistant would
      # answer product questions out of nothing.
      def complete?(rows)
        (Docs::Contract::LOCALES - rows.map { |row| row[:locale] }).empty?
      end

      # A digest over [*KEY_COLUMNS, content_hash] tuples, in any order. Built once from the
      # source rows (see tuples) and once from the table (a pluck), so the two compare.
      def fingerprint(tuples)
        Digest::SHA256.hexdigest(tuples.map { |tuple| tuple.join("\t") }.sort.join("\n"))
      end

      def tuples(rows)
        rows.map { |row| row.values_at(*KEY_COLUMNS, :content_hash) }
      end

      def key_of(row)
        row.values_at(*KEY_COLUMNS)
      end

      # One row with its content_hash: the ONE place the hash is computed. Hashed as JSON, so
      # the column boundaries stay part of the input and moving words between two columns
      # still changes it. Unknown columns raise instead of vanishing.
      def build_row(**columns)
        unknown = columns.keys - WRITTEN_COLUMNS
        raise ArgumentError, "unknown product knowledge columns: #{unknown.join(', ')}" if unknown.any?

        row = WRITTEN_COLUMNS.index_with { |column| columns[column] }
        row.merge(content_hash: Digest::SHA256.hexdigest(row.values.to_json))
      end

      private

      def help_rows
        Docs::Contract::LOCALES.flat_map do |locale|
          Docs::Catalogue.for(locale)&.pages.to_a.map { |page| help_row(page) }
        end
      end

      def help_row(page)
        build_row(
          source: HELP, locale: page.locale, slug: page.slug, title: page.title.to_s,
          section: page.section_title,
          description: page.description.to_s, body_markdown: page.markdown.to_s,
          body_text: page.text.to_s, published_on: nil
        )
      end
    end
  end
end
