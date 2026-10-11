# frozen_string_literal: true

# Reads the catalogue that gboyke/lalabase-documentation writes at deploy time,
# which is where the in-app help gets its pages since the documentation became
# its own program (doc/docs_delivery_plan.md, D3 and D4).
#
# A file and not a service call: both programs bind a unix socket and nothing
# else, and config/puma.rb forbids a TCP port here after one bypassed the
# password gate in front of staging. So the help does not depend on a second
# process being up, only on a file being there.
#
# ⚠️ NOT being there is the normal case in three places: a self-hosted instance
# (deliberate, the documentation is not part of the open source core), a
# development machine that has not fetched one, and CI outside the help specs.
# Every reader here answers nil or empty rather than raising, and the help
# surface turns that into links to the public documentation.
#
# Entry point: .for
module Docs
  class Catalogue
    Page = Struct.new(:slug, :title, :section, :section_title, :description,
                      :html, :markdown, :text, :locale, keyword_init: true)
    Group = Struct.new(:section, :title, :items, keyword_init: true)
    Item = Struct.new(:slug, :title, :active, keyword_init: true)
    Result = Struct.new(:slug, :title, :section, :snippet, keyword_init: true)

    # The shape written by the other program. A file that says something else is
    # treated as absent, loudly in the log: reading half a format is worse than
    # reading none, because the help would render pages with holes in them.
    SUPPORTED_FORMAT = 1

    class << self
      # The catalogue for a language, or nil when there is none to read.
      def for(locale)
        locale = Contract.locale_or_default(locale)
        data = load(locale)
        data && new(locale: locale, data: data)
      end

      # A page in the requested language, or the German one when that language
      # has no translation of it. The returned page carries the language it IS,
      # which is what the help banner announces: silently swapping the content
      # would leave a reader wondering why the page is in another language.
      #
      # The fallback crosses FILES here, where it used to cross directories.
      def find_page(locale, slug)
        locale = Contract.locale_or_default(locale)
        page = self.for(locale)&.page(slug)
        return page if page
        return nil if locale == Contract::DEFAULT_LOCALE

        self.for(Contract::DEFAULT_LOCALE)&.page(slug)
      end

      # Is there a catalogue AT ALL? Deliberately not "in this language": a page
      # missing in English is served from German, so an instance that has only
      # one file still has a working help. Gating on the request's language
      # would send an English reader to the public documentation while a German
      # one reads the same page locally.
      def available?
        Contract::LOCALES.any? { |locale| load(locale) }
      end

      def directory
        path = ENV.fetch('DOCS_CATALOGUE_PATH', nil)
        path.presence && Pathname.new(path)
      end

      # Size and change time of one language's file, or nil when there is none.
      # Same SHAPE as the file stamp the product knowledge compared before the
      # split ([count, time]), so its "a generation never moves backwards" rule
      # keeps working on the second element without knowing what changed.
      def stamp(locale)
        file = path_for(locale)
        return nil unless file&.exist?

        stat = file.stat
        [stat.size, stat.mtime.to_i]
      rescue SystemCallError
        nil
      end

      # The locale is normalised HERE and not by each caller: the file name is
      # built from it, and an allowlist that every caller has to remember is one
      # caller away from not being an allowlist.
      def path_for(locale)
        directory&.join("docs_catalogue.#{Contract.locale_or_default(locale)}.json")
      end

      # Only for tests and for the rake task that refreshes the fixture.
      def reset_cache! = @cache = {}

      private

      # Parsed once per file version and kept in this process. The check is one
      # stat per call, which is what the page cache did before the split; the
      # alternative, deserialising a megabyte from a shared cache on every
      # request, costs more than it saves.
      def load(locale)
        file = path_for(locale)
        return nil unless file&.exist?

        stamp = begin
          stat = file.stat
          # to_r, not to_i: whole seconds are too coarse. Two catalogues written
          # in the same second with the same size look identical, and the help
          # goes on serving the previous one. Found by the spec below, which
          # rewrites a file of equal length; a deploy would usually differ in
          # both, which is exactly why nobody would have noticed.
          [file.to_s, stat.mtime.to_r, stat.size]
        rescue SystemCallError
          return nil
        end

        cached = cache[locale]
        return cached[:data] if cached && cached[:stamp] == stamp

        data = parse(file)
        cache[locale] = { stamp: stamp, data: data }
        data
      end

      def parse(file)
        data = JSON.parse(file.read, symbolize_names: true)
        return refuse(file, "format_version #{data[:format_version].inspect}") unless
          data[:format_version] == SUPPORTED_FORMAT

        # The version alone is not enough. A file that says version 1 and holds
        # no pages passed this check and then raised NoMethodError inside a
        # request, which is the opposite of treating a bad file as an absent
        # one. Structure is part of the format.
        return refuse(file, 'pages is not a list') unless data[:pages].is_a?(Array)
        return refuse(file, 'groups is not a list') unless data[:groups].is_a?(Array)

        data
      rescue JSON::ParserError, SystemCallError => e
        # A half-written file cannot happen (the writer renames into place), but
        # a truncated disk or a wrong path can. Treat it as absent.
        Rails.logger.error("Docs::Catalogue: cannot read #{file}: #{e.message}")
        nil
      end

      def refuse(file, reason)
        Rails.logger.error("Docs::Catalogue: refusing #{file}: #{reason}")
        nil
      end

      def cache = @cache ||= {}
    end

    attr_reader :locale

    # Keyword arguments, per the service convention. Callers go through .for
    # anyway, which is the entry point; this one exists for it and for specs.
    def initialize(locale:, data:)
      @locale = locale
      @data = data
    end

    def pages = @pages ||= @data[:pages].map { |page| build_page(page) }

    def page(slug) = pages.find { |page| page.slug == slug }

    def first_page = pages.first

    # The sidebar tree, already ordered by the other program: this side sorts
    # nothing and reads no front matter.
    def groups(current_slug: nil)
      @data[:groups].map do |group|
        Group.new(
          section: group[:section],
          title: group[:title],
          items: group[:items].map do |item|
            Item.new(slug: item[:slug], title: item[:title], active: item[:slug] == current_slug)
          end
        )
      end
    end

    # Title and body, case-insensitive, with a snippet around the hit. The
    # ranking the engine had is gone with it; what the help search needs is to
    # find the page, and the list is short.
    def search(term)
      term = term.to_s.strip
      return [] if term.length < Contract::MIN_TERM_LENGTH

      needle = term.downcase
      pages.filter_map do |page|
        # to_s on both: a page whose text or title arrived as null is a broken
        # catalogue, and the help staying up beats a search that raises.
        idx = page.text.to_s.downcase.index(needle)
        next if idx.nil? && !page.title.to_s.downcase.include?(needle)

        Result.new(slug: page.slug, title: page.title, section: page.section_title,
                   snippet: PlainText.excerpt(page.text.to_s, idx))
      end
    end

    private

    def build_page(page)
      Page.new(**page.slice(:slug, :title, :section, :section_title, :description,
                            :html, :markdown, :text),
               locale: @locale)
    end
  end
end
