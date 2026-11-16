# frozen_string_literal: true

# Entry point: .apply
module ObjectLinks
  # Shows a link to an object of this instance as a chip: type icon and label instead of
  # the long address (Objekt-Links plan, round 1). Called by ObjectLinksHelper from the
  # ActionText layout, so comments, ticket descriptions and notes all pass through here.
  #
  # Replaced at DISPLAY time only. The stored rich text keeps the plain link, so mails,
  # search, embeddings, plain text and API answers keep the real address, and the rule
  # holds for everything already written and for whatever arrives through API, MCP or an
  # import.
  #
  # Only a link whose text IS its own address becomes a chip: an author who gave a link
  # wording of their own keeps it. Only an address ObjectLinks::Address reads (this
  # instance, this organisation) and only a target ObjectLinks::Targets labels for this
  # reader. Everything else stays exactly the markup it was: nothing is reserialised
  # unless a chip went in.
  #
  # Runs AFTER the sanitiser, on its output (the layout wraps the sanitised content), like
  # Lalabase::CitationInlineLinks: the chip carries data-turbo-frame="_top", which the
  # sanitiser would strip. Without it a chip inside a lane (a turbo-frame) loads the target
  # page INTO the lane and shows "Content missing". Everything inserted is escaped text,
  # the address is the author's own, already sanitised and read by Address.
  module Chips
    # The icon of a type: the citation list's map, so a ticket wears the same glyph in an
    # answer's sources and in a comment. A member is a person.
    ICON_TYPES = { member: 'person' }.freeze

    module_function

    # @return [String] the html, html_safe; the input itself when nothing was replaced
    def apply(html:, viewer:, organisation:, hosts:)
      text = html.to_s
      return html unless candidate_text?(text, organisation)

      fragment = Nokogiri::HTML5::DocumentFragment.parse(text)
      links = own_links(fragment, organisation, hosts)
      return html if links.empty?

      targets = Current.object_link_targets(viewer, organisation).resolve(links.map(&:last))
      replaced = links.count do |anchor, ref|
        target = targets[ref]
        anchor.replace(chip_html(href: anchor['href'], target: target)) if target
      end
      replaced.zero? ? html : fragment.to_html.html_safe # rubocop:disable Rails/OutputSafety
    end

    # Loads the targets of many rich texts at once (a timeline before its comments render).
    # @param htmls [Array<String>] the stored bodies (ActionText::Content#to_html)
    def prefetch(htmls:, viewer:, organisation:, hosts:)
      refs = htmls.flat_map do |text|
        next [] unless candidate_text?(text.to_s, organisation)

        own_links(Nokogiri::HTML5::DocumentFragment.parse(text.to_s), organisation, hosts).map(&:last)
      end
      Current.object_link_targets(viewer, organisation).load(refs) if refs.any?
    end

    # The markup of one chip, every part escaped. Public for the style guide, which shows
    # the real thing.
    def chip_html(href:, target:)
      type_name = I18n.t("views.object_links.types.#{target.type}")
      icon = Neo::Chat::CitationListComponent::ICON_MAP.fetch(
        ICON_TYPES.fetch(target.type, target.type.to_s), Neo::Chat::CitationListComponent::FALLBACK_ICON
      )
      html = [
        %(<a href="#{escape(href)}" class="object-chip object-chip--#{target.type}" ),
        %(title="#{escape(target.full_label)}" data-turbo-frame="_top">),
        %(<i class="bi #{icon}" aria-hidden="true"></i>),
        %(<span class="object-chip__type">#{escape(type_name)}: </span>),
        %(<span class="object-chip__label">#{escape(target.label)}</span></a>)
      ].join
      html.html_safe # rubocop:disable Rails/OutputSafety
    end

    # A text that holds no path into the organisation holds no address Address could read:
    # no parsing, no query.
    def candidate_text?(text, organisation)
      text.include?("/org/#{organisation.id}/")
    end

    # [[anchor, ref], ...] for the links whose text is their own address and that name an
    # object. Links inside code stay code.
    def own_links(fragment, organisation, hosts)
      fragment.css('a[href]').filter_map do |anchor|
        href = anchor['href'].to_s
        next unless anchor.text.strip == href.strip
        next if anchor.ancestors.any? { |node| %w[code pre].include?(node.name) }

        ref = Address.parse(href, organisation_id: organisation.id, hosts: hosts)
        [anchor, ref] if ref
      end
    end

    def escape(text)
      CGI.escapeHTML(text.to_s)
    end

    private_class_method :candidate_text?, :own_links, :escape
  end
end
