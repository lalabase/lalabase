# frozen_string_literal: true

# StripDown is a pure-Ruby Redcarpet renderer that is NOT autoloaded by
# `require 'redcarpet'` (only the C core is), so it must be required explicitly.
require 'redcarpet/render_strip'

module Documentation
  # Projects a page's markdown source down to plain text for the embedding
  # pipeline (the EmbeddingProcessingService#extract_text_fragments contract).
  #
  # Why StripDown and not the rendered_html: markdown_body is the page's canonical
  # source (see DocumentationPage's header), and StripDown is PURPOSE-BUILT for
  # markdown→text — it degrades links to "text (url)", drops #/*/`/table pipes,
  # and keeps code as plain text — so the embedding vector carries meaning, not
  # syntax noise. A hand-rolled regex stripper would be both less correct and
  # harder to read (Slice-3 review lens #4).
  class PlainTextRenderer
    # extensions: Redcarpet options for the engine. The embedding pipeline
    # passes none, as it always has. A caller projecting identifiers rather
    # than prose passes the ones that keep them whole (no_intra_emphasis,
    # space_after_headers): by default "waiting_for_customer" reads as emphasis
    # and "#123" as a heading. The timeline reads its values through
    # Lalabase::SafeMarkdown.plain_text instead, and only for text columns.
    def initialize(**extensions)
      @extensions = extensions
    end

    def render(markdown)
      return '' if markdown.blank?

      engine.render(markdown.to_s)
    end

    private

    # Built fresh per call for the SAME thread-safety reason as MarkdownRenderer:
    # a Redcarpet::Markdown instance reuses internal work buffers and is not
    # thread-safe, and the embedding jobs that call this run in parallel Solid
    # Queue workers. Instantiation cost is negligible next to generating the
    # embedding vector afterwards.
    def engine
      Redcarpet::Markdown.new(Redcarpet::Render::StripDown, **@extensions)
    end
  end
end
