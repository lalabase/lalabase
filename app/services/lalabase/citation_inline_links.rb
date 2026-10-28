# frozen_string_literal: true

# Entry point: .apply
module Lalabase
  # Turns the objects an answer NAMES into links (Feinschliff C, plan P1).
  #
  # The whitelist is the answer's own citations, never the text. Two reasons, both
  # load-bearing:
  #
  #   * A number in prose addresses nothing on its own: ticket numbers are unique
  #     per PROJECT, and an org-wide thread spans many. The citation carries the
  #     project and the id, frozen at retrieval.
  #   * The citations handed in are already gated for this viewer
  #     (MessageComponent#visible_citations, minus the ones whose target is gone).
  #     Linking only what is cited means the prose can never name an object the
  #     source list is hiding, and can never link into a deleted record.
  #
  # Runs AFTER the sanitiser, on its output: the turbo escape is a data attribute
  # and the allowlist has none, so an anchor that survives sanitising cannot carry
  # it. Everything inserted here is built from route helpers and escaped text —
  # nothing from the model reaches the markup unescaped.
  module CitationInlineLinks
    # A title shorter than this is not looked for at all: "Tag" or "Plan" as a note
    # title would light up ordinary prose. Numbers are exempt — they carry their own
    # marker (#42, "Aufgabe 42").
    MIN_TITLE_LENGTH = 4

    # Text inside these is never touched: a ticket number in a code sample is code,
    # and a link inside a link is invalid markup.
    SKIP_ANCESTORS = %w[a code pre].freeze

    # Types that get a title match. `post` is absent (a comment has no title of its
    # own), `time_report` too: its title is the PROJECT name, which appears in half
    # the sentences of an org-wide answer, and it has a panel rather than a page.
    TITLE_TYPES = %w[note document documentation meeting meeting_analysis].freeze

    # Types matched by their name, the same way (People S3): a person has a name rather
    # than a title, and the answer names the person it found.
    NAME_TYPES = %w[person].freeze

    module_function

    # @param html [String] sanitised answer html
    # @param citations [Array<Hash>] the citations this viewer may see, targets alive
    # @param numbering [Lalabase::ProjectRag::SourceNumbering, nil] the numbering over
    #   the FULL persisted source_citations — the same [n] the prompt showed the
    #   model, so a "[3]" in prose resolves to the citation the model called [3].
    # @return [String] html_safe
    def apply(html:, citations:, organisation:, project: nil, numbering: nil)
      text = html.to_s
      anchors = build_anchors(citations, organisation, project, numbering)
      return text.html_safe if anchors.empty? || text.blank? # rubocop:disable Rails/OutputSafety

      fragment = Nokogiri::HTML::DocumentFragment.parse(text)
      link_text_nodes(fragment, anchors)
      fragment.to_html.html_safe # rubocop:disable Rails/OutputSafety
    end

    # One anchor per WORDING, not per citation — and only where that wording means
    # exactly one thing (review of #624). Every OCCURRENCE of an anchor's wording
    # is linked (R1, 2026-08-31; before that only the first, which readers
    # consistently reported as "sometimes linked, sometimes not").
    #
    # Two ways several citations produce the same pattern, with opposite answers:
    #
    #   * Same address. A ticket and its two comments are three citations and ONE
    #     source (PR B), so "#42" is ONE anchor. Without the collapse three
    #     identical anchors would fight over the same matches for nothing.
    #   * Different addresses. An org-wide answer can cite #42 from project A AND
    #     #42 from project B; ticket numbers are unique per project. Nothing in the
    #     text says which one a given sentence means, and the array order has
    #     nothing to do with it. So neither is linked: a wrong link is worse than
    #     plain text, and this is the very ambiguity the module header claims to
    #     avoid.
    def build_anchors(citations, organisation, project, numbering = nil)
      list = citations.is_a?(Array) ? citations : []
      candidates = list.filter_map do |citation|
        next unless citation.is_a?(Hash)

        pattern = pattern_for(citation)
        next if pattern.nil?

        href = Lalabase::CitationLink.path_for(citation, organisation: organisation, project: project)
        next if href.blank?

        { pattern: pattern, href: href }
      end
      candidates += marker_candidates(list, organisation, project, numbering)

      # Keyed on the pattern SOURCE: two Regexp objects built from the same title or
      # the same number are never equal as objects, and it is the wording that
      # collides, not the object.
      candidates.group_by { |candidate| candidate[:pattern].source }.filter_map do |_source, group|
        group.first if group.map { |candidate| candidate[:href] }.uniq.one?
      end
    end

    # "[3]" markers (R2): the model already peppers its prose with the source
    # numbers the prompt showed it, and SourceNumbering owns the mapping number n =
    # source_citations[n-1] in BOTH existing directions (PromptBuilder forward,
    # apply_used_flags backward). Resolving the marker through the same numbering
    # makes the link correct by construction: it can only reach an object persisted
    # as a source of this very answer.
    #
    # Only citations from the gated `list` get an anchor — a number whose citation
    # is hidden for this viewer (or whose target is gone) stays literal text, which
    # leaks nothing. Code citations resolve to no href and stay text too.
    def marker_candidates(list, organisation, project, numbering)
      return [] if numbering.nil? || !numbering.active?

      list.filter_map do |citation|
        next unless citation.is_a?(Hash)

        number = numbering.number_for(citation['type'], citation['id'])
        next if number.nil?

        href = Lalabase::CitationLink.path_for(citation, organisation: organisation, project: project)
        next if href.blank?

        { pattern: marker_pattern(number), href: href }
      end
    end

    # Literal "[3]". The lookbehind keeps it off an index expression glued to a
    # word ("items[3]" is prose about code); "[34]" cannot match a [3] anchor
    # because the pattern requires the closing bracket right after the digits.
    def marker_pattern(number)
      /(?<!\w)\[#{Regexp.escape(number.to_s)}\]/
    end

    # What the answer would have written for this object.
    def pattern_for(citation)
      case citation['type']
      when 'ticket' then number_pattern(citation['number'])
      when 'post'   then number_pattern(citation['ticket_number'])
      when *NAME_TYPES then title_pattern(citation['name'])
      else
        return nil unless TITLE_TYPES.include?(citation['type'])

        title_pattern(citation['title'])
      end
    end

    # "#42", "Ticket 42", "Aufgabe #42", "Task 42". The lookbehind keeps it off a
    # number glued to a word (a commit hash, a price), and the trailing (?!\w) keeps
    # #42 out of #420 and out of #42abc — \b alone would not, since it sits between
    # two word characters in the first case.
    #
    # Deliberately (?!\w) and NOT (?![\w-]): a hyphen after the number is how a
    # RANGE is written ("Aufgaben #42-#45"), and the first number of a range is a
    # real mention.
    def number_pattern(number)
      return nil if number.blank?

      digits = Regexp.escape(number.to_s)
      /(?<![\w#])(?:(?:Ticket|Aufgabe|Task)\s*\#?#{digits}|\##{digits})(?!\w)/i
    end

    # The exact title, at word boundaries, case-insensitively — the model tends to
    # copy a title verbatim but not always its capitalisation. Escaped, because a
    # title is user input and "Preise (2026)" is a valid regex that matches nothing.
    def title_pattern(title)
      value = title.to_s.strip
      return nil if value.length < MIN_TITLE_LENGTH

      /(?<!\w)#{Regexp.escape(value)}(?!\w)/i
    end

    def link_text_nodes(fragment, anchors)
      fragment.xpath('.//text()').each do |node|
        next if skip?(node)

        replacement = linked_html(node.text, anchors)
        node.replace(replacement) if replacement
      end
    end

    def skip?(node)
      node.ancestors.any? { |ancestor| SKIP_ANCESTORS.include?(ancestor.name) }
    end

    # Rebuilds ONE text node with anchors woven in, or nil when nothing matched (so
    # the node is left untouched rather than re-serialised). Every occurrence is
    # linked (R1): pos advances past each match, so one anchor can fire repeatedly
    # without ever re-matching the same characters.
    def linked_html(text, anchors)
      out = +''
      pos = 0
      matched = false

      while (found = next_match(text, pos, anchors))
        match, anchor = found
        out << escape(text[pos...match.begin(0)])
        out << anchor_html(anchor[:href], match[0])
        matched = true
        pos = match.end(0)
      end
      return nil unless matched

      out << escape(text[pos..])
      out
    end

    # The earliest match in the rest of the node; on a tie the longer one, so
    # a title never loses the position to a shorter one that starts there too.
    def next_match(text, pos, anchors)
      best = nil
      anchors.each do |anchor|
        match = anchor[:pattern].match(text, pos)
        next if match.nil?

        best = [match, anchor] if best.nil? || better?(match, best[0])
      end
      best
    end

    def better?(candidate, current)
      return true if candidate.begin(0) < current.begin(0)

      candidate.begin(0) == current.begin(0) && candidate[0].length > current[0].length
    end

    # The label is the text the ANSWER wrote, escaped — never a rebuilt label. The
    # sentence keeps its wording, and nothing from the model becomes markup.
    #
    # data-turbo-frame="_top" for the same reason the source list carries it: this
    # renders inside the chat's turbo frame, and without the escape Turbo loads the
    # target page INTO that frame and shows "Content missing" instead of navigating.
    def anchor_html(href, label)
      %(<a href="#{escape(href)}" data-turbo-frame="_top">#{escape(label)}</a>)
    end

    def escape(text)
      CGI.escapeHTML(text.to_s)
    end

    private_class_method :build_anchors, :marker_candidates, :marker_pattern,
                         :pattern_for, :number_pattern, :title_pattern,
                         :link_text_nodes, :skip?, :linked_html, :next_match, :better?,
                         :anchor_html, :escape
  end
end
