# frozen_string_literal: true

require 'redcarpet/render_strip'

# Entry point: .render (and .plain_text, the same Markdown read as one line)
module Lalabase
  # Shared safe-Markdown renderer: render user-authored Markdown to HTML and THEN
  # sanitise it against a strict allowlist — TWO layers, because `filter_html: true`
  # already strips raw HTML from the SOURCE (a human — or an LLM coaxed by a prompt —
  # can emit a <script>), and the allowlist sanitiser is the second gate on the
  # rendered output. Extracted from Neo::Chat::MessageComponent so the chat bubbles
  # AND the meeting detail share ONE renderer + allowlist instead of a fifth copy.
  #
  # Deliberately NO <img> (a tracking-pixel / exfil vector — meetings are PII-dense)
  # and NO <table> (prior chat audit decision; also disabled in the renderer). The
  # allowlist lists EXACTLY what the renderer below can emit.
  module SafeMarkdown
    # What counts as Markdown here - shared by both readings below, so the typeset
    # one and the plain one agree on every mark (no_intra_emphasis: snake_case_name
    # is a word, not emphasis).
    EXTENSIONS = { autolink: true, fenced_code_blocks: true,
                   strikethrough: true, no_intra_emphasis: true, lax_spacing: true }.freeze

    # A single renderer instance is safe to SHARE across threads: with neither TOC
    # nor footnotes enabled, Redcarpet#render keeps no per-call state. Enabling TOC
    # or footnotes WOULD make it stateful — do NOT "improve" this by turning them on.
    MARKDOWN = Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(filter_html: true, no_images: true,
                                  no_styles: true, hard_wrap: true),
      EXTENSIONS
    )

    # Allowlist for the final sanitise. Lists EXACTLY what the renderer above can
    # emit — paragraphs, emphasis (strong/em), headings, code, lists, blockquotes,
    # links, rules. Deliberately NOT <img> (a tracking-pixel vector) or <table>
    # (also disabled in the renderer). No <b>/<i>/<u>/<span>: Markdown emits
    # <strong>/<em>, never those, so listing them would be dead entries.
    ALLOWED_TAGS = %w[p br strong em code pre ul ol li blockquote a
                      h1 h2 h3 h4 h5 h6 hr].freeze
    ALLOWED_ATTRIBUTES = %w[href title lang].freeze

    module_function

    # Renders `text` (Markdown) to sanitized, html_safe HTML. Blank in → a blank
    # html_safe String (callers render it raw). The sanitize result is html_safe BY
    # DESIGN — it is allowlist-filtered, which is the whole point of the two layers.
    def render(text)
      return ''.html_safe if text.blank?

      html = MARKDOWN.render(text.to_s)
      helpers.sanitize(html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
    end

    # `text` (Markdown) as one line of plain text, for a value that stands inside
    # a sentence instead of being typeset (a timeline line): the marks gone,
    # paragraphs and line breaks folded into spaces. NOT html_safe - it is text,
    # and the caller escapes it like any other string. Blank in → ''.
    #
    # ⚠️ A NEW parser per call, unlike MARKDOWN above. StripDown is a Ruby
    # renderer, so Redcarpet calls back into Ruby for every element, and a
    # thread switch at one of those calls would let a second render reuse the
    # parser's per-render C state (refs, work buffers) mid-flight. The pure-C
    # HTML renderer never yields, which is why sharing MARKDOWN holds. A parser
    # costs microseconds; a garbled line or an aborted worker does not.
    def plain_text(text)
      return '' if text.blank?

      Redcarpet::Markdown.new(Redcarpet::Render::StripDown, EXTENSIONS).render(text.to_s).squish
    end

    # `sanitize` lives on the view/controller helpers; this PORO can run outside any
    # view (e.g. a broadcast render), so it reaches them via ActionController::Base
    # .helpers — the SAME access path as Documentation::MarkdownRenderer.
    def helpers
      ActionController::Base.helpers
    end
  end
end
