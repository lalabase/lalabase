# frozen_string_literal: true

module Wiki
  # Extracts the link targets of a note from its CANONICAL HTML (the sgid mention
  # attachments) — NOT from the derived markdown, so a serializer bug can never
  # corrupt the link graph (design D3).
  #
  #   html ──▶ [target record, ...]   (unique, resolvable, e.g. Note / Document)
  #
  # Unresolvable mentions (deleted or forged sgid) are skipped; together with the
  # DB unique index and this de-dup, a note links to each target at most once.
  # The resolution itself is delegated to MentionResolver (reused, not duplicated).
  class ReferenceExtractor
    def initialize(resolver: MentionResolver.new)
      @resolver = resolver
    end

    def call(html)
      return [] if html.blank?

      fragment = Nokogiri::HTML.fragment(html.to_s)
      Wiki::Mention.nodes(fragment)
                   .filter_map { |node| @resolver.record_for(node['sgid']) }
                   .uniq
    end
  end
end
