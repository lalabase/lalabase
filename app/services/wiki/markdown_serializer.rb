# frozen_string_literal: true

module Wiki
  # Converts between ActionText HTML (the canonical source of truth) and
  # GFM Markdown (the derived markdown_body column used for diff / import / MCP).
  #
  #   ActionText HTML ──to_markdown──▶ GFM Markdown   (markdown_body)
  #   GFM Markdown    ──to_html──────▶ ActionText HTML (MCP write path, phase 2)
  #
  # ONE serializer for ALL paths (design premise 6): backfill job, Note callback,
  # later the MCP write path. If it were duplicated, the paths would drift and
  # diffs would show pipeline differences instead of content differences.
  #
  # Content invariant (design premise 8): a note may only contain content that
  # survives the HTML→MD→HTML round trip unscathed. For tables that means
  # GFM-simple:
  #   - Merged cells (colspan/rowspan) are already prevented by Lexxy itself (no
  #     merge UI + its sanitizer strips the span attributes at boot) — nothing to do here.
  #   - Block content inside cells (lists/paragraphs/nested tables) is NOT prevented
  #     by Lexxy but breaks the round trip (confirmed empirically in the spike) → it is
  #     rejected here via a guard (BlockContentInTableCellError). The caller (Note
  #     validation / MCP) turns that into a usable error instead of a silent loss.
  #
  # Mentions are ActionText attachments
  # (<action-text-attachment sgid content-type="application/vnd.actiontext.mention">).
  # They become Markdown placeholders [Title](lalabase:type/UUID). The placeholder
  # carries type+UUID, NEVER the signed sgid — the server mints that fresh on the way
  # back after a policy_scope check (no forgeable token travels through an AI).
  class MarkdownSerializer
    INTERNAL_SCHEME = 'lalabase'

    # Block tags that would break a GFM table cell (which allows inline content only).
    CELL_BREAKING_TAGS = %w[ul ol pre blockquote table hr figure div h1 h2 h3 h4 h5 h6].freeze

    # Precomputed CSS selectors — built once, not rebuilt per cell inside the loops below.
    TABLE_CELL_SELECTOR = 'td, th'
    CELL_BREAKING_SELECTOR = CELL_BREAKING_TAGS.join(', ').freeze

    class BlockContentInTableCellError < StandardError; end

    # mention_resolver: responds to #call(sgid) → { type:, id:, title: } or nil.
    # Default = Wiki::MentionResolver (GlobalID resolution). Injectable in tests so
    # the serializer stays testable without DB/GlobalID (pure transformation).
    def initialize(mention_resolver: MentionResolver.new)
      @mention_resolver = mention_resolver
    end

    # ActionText HTML → GFM Markdown.
    def to_markdown(html)
      return '' if html.blank?

      fragment = Nokogiri::HTML.fragment(html.to_s)
      unwrap_cell_paragraphs!(fragment)
      guard_table_cells!(fragment)
      rewrite_mentions_to_links!(fragment)
      escape_pipes_in_table_cells!(fragment)

      ReverseMarkdown.convert(fragment.to_html, github_flavored: true).strip
    end

    # GFM Markdown → HTML (comrak, GFM-native). Deliberately NOT unsafe: comrak's safe
    # mode already keeps our internal lalabase: scheme (it only blocks javascript:/data:/
    # vbscript:/file:) while stripping raw HTML and neutralizing dangerous hrefs — so the
    # MD→HTML path is XSS-safe by default, which matters for the future MCP write path that
    # feeds attacker-controlled Markdown here. (unsafe:true was unnecessary for lalabase:
    # and only re-opened the raw-HTML / javascript:-href sink.) Turning lalabase: links back
    # into sgid attachments is phase 2 and is deliberately not included here yet.
    def to_html(markdown)
      return '' if markdown.blank?

      Commonmarker.to_html(markdown.to_s, options: { extension: { table: true } })
    end

    # Checks the content invariant without fully serializing: raises
    # BlockContentInTableCellError on block content in cells. For validations that
    # want a usable error instead of an exception (Note#validate).
    def assert_roundtrip_safe!(html)
      return if html.blank?

      fragment = Nokogiri::HTML.fragment(html.to_s)
      unwrap_cell_paragraphs!(fragment) # same normalization as to_markdown, so the guard judges the same shape
      guard_table_cells!(fragment)
    end

    private

    # Lexxy wraps each cell's content in a single <p> (its canonical table structure).
    # GFM cells are inline-only, so we unwrap a LONE paragraph back to its inline content
    # before converting — otherwise reverse_markdown emits block breaks inside the cell and
    # shatters the pipe table. A cell with more than one paragraph (or a <p> alongside other
    # content) is genuinely multi-block: we leave it intact so the guard rejects it.
    def unwrap_cell_paragraphs!(fragment)
      fragment.css(TABLE_CELL_SELECTOR).each do |cell|
        # Only unwrap when the <p> is the cell's SOLE meaningful child. element_children
        # alone would ignore text nodes, so <td>Lead<p>x</p></td> would silently lose
        # "Lead"; instead we leave such a cell intact and let the guard reject it as block
        # content (blank whitespace text nodes around the <p> are fine to ignore).
        meaningful = cell.children.reject { |node| node.text? && node.text.blank? }
        next unless meaningful.size == 1 && meaningful.first.name == 'p'

        cell.inner_html = meaningful.first.inner_html
      end
    end

    def guard_table_cells!(fragment)
      fragment.css(TABLE_CELL_SELECTOR).each do |cell|
        # After unwrap_cell_paragraphs!, a lone Lexxy <p> is gone; a remaining <p> means a
        # multi-paragraph cell, which is block content and not GFM-simple → reject it too.
        next if cell.css(CELL_BREAKING_SELECTOR).empty? && cell.css('p').empty?

        raise BlockContentInTableCellError,
              'Table cells may not contain block content (inline only, GFM-simple)'
      end
    end

    def rewrite_mentions_to_links!(fragment)
      Mention.nodes(fragment).each do |node|
        node.replace(link_node_for(fragment, node))
      end
    end

    def link_node_for(fragment, attachment)
      resolved = @mention_resolver.call(attachment['sgid'])

      unless resolved
        # Not resolvable (e.g. deleted target) → plain text instead of a dead link.
        return Nokogiri::XML::Text.new(attachment['content'].to_s, fragment.document)
      end

      node = Nokogiri::XML::Node.new('a', fragment.document)
      node['href'] = "#{INTERNAL_SCHEME}:#{resolved[:type]}/#{resolved[:id]}"
      node.content = resolved[:title].to_s
      node
    end

    # Escape pipes WITHIN cell content BEFORE reverse_markdown builds the pipe rows.
    # Otherwise GFM reads a content "|" as a column separator → broken table.
    # (reverse_markdown does not escape them itself — spike finding.)
    def escape_pipes_in_table_cells!(fragment)
      fragment.css(TABLE_CELL_SELECTOR).each do |cell|
        cell.traverse do |child|
          child.content = child.content.gsub('|', '\|') if child.text?
        end
      end
    end
  end
end
