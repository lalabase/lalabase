# frozen_string_literal: true

module Documentation
  # Renders one synced .md page to sanitized HTML for display. Two safety layers
  # (Neo::Chat::MessageComponent pattern): Redcarpet strips raw HTML from the
  # source (filter_html), then a strict allowlist sanitizer is the second gate.
  #
  # It also rewrites three kinds of reference produced by repo authors:
  #   * internal links to other .md pages   → the in-app documentation route
  #   * knowledge links (lalabase://…)      → the in-app note/document page, and
  #     the resolved target is collected so the sync job can index a Reference row
  #     (Slice 4; see KnowledgeLinkResolver for the tenant/project isolation)
  #   * images                              → served by the instance, or not shown:
  #     a relative image gets the address the asset resolver gives (the sync hands
  #     in Documentation::AssetCollector, which copies the file out of the clone);
  #     one that is not served shows as its alt text; one with a foreign address
  #     becomes a link. A page makes no browser load from the repository host or
  #     from anywhere else.
  class MarkdownRenderer
    ALLOWED_TAGS = %w[
      p br strong em code pre ul ol li blockquote a img
      h1 h2 h3 h4 h5 h6 hr table thead tbody tr th td
    ].freeze
    ALLOWED_ATTRIBUTES = %w[href title lang src alt].freeze

    MARKDOWN_EXTENSIONS = %w[.md .markdown].freeze

    # Result of render_with_references: the sanitized HTML plus the knowledge
    # objects this page successfully linked to (deduped), for the Reference index.
    Result = Struct.new(:html, :references, keyword_init: true)

    # documentation_set: the set the page belongs to (for route + repo context).
    # page_path: the page's path relative to the set's path_prefix.
    # asset_resolver: answers #address_for(path in the repository) with the address an
    #   image is served from, or nil. Without one no relative image is shown.
    def initialize(documentation_set:, page_path:, asset_resolver: nil)
      @documentation_set = documentation_set
      @page_path = page_path
      @asset_resolver = asset_resolver
    end

    # Backward-compatible string entry point (browsing preview, tests): the HTML only.
    def render(markdown)
      render_with_references(markdown).html
    end

    # Full entry point used by the sync job: the HTML AND the resolved knowledge
    # targets, so the job can rebuild the page's Reference rows in the same pass
    # the renderer already walked (no second parse).
    def render_with_references(markdown)
      return Result.new(html: '', references: []) if markdown.blank?

      html = markdown_engine.render(markdown.to_s)
      html, references = rewrite_references(html)
      sanitized = sanitizer.sanitize(html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
      Result.new(html: sanitized, references: references)
    end

    private

    # Built fresh per call ON PURPOSE (not a shared constant): a
    # Redcarpet::Markdown instance reuses internal work buffers across #render
    # calls and is not thread-safe. This renderer runs inside threaded Solid
    # Queue workers where two sets can sync in parallel (the advisory lock only
    # serialises runs per set). Instantiation cost is negligible next to the
    # clone and per-page DB writes.
    def markdown_engine
      Redcarpet::Markdown.new(
        Redcarpet::Render::HTML.new(filter_html: true, no_styles: true, hard_wrap: true),
        autolink: true, fenced_code_blocks: true, tables: true,
        strikethrough: true, no_intra_emphasis: true, lax_spacing: true
      )
    end

    # Returns [rewritten_html, resolved_knowledge_targets]. Every anchor is offered
    # to the knowledge-link resolver FIRST (lalabase:// scheme), then — only if that
    # was not a knowledge link — to the internal .md-page rewrite. The two are
    # mutually exclusive by scheme, so the order just avoids a needless second check.
    def rewrite_references(html)
      fragment = Nokogiri::HTML.fragment(html)
      references = []

      anchors = fragment.css('a[href]')
      # Resolve ALL knowledge links up front in a fixed number of queries (see
      # KnowledgeLinkResolver#resolve_all), then rewrite each anchor from the map —
      # never a query per link.
      resolved = knowledge_link_resolver.resolve_all(anchors.map { |node| node['href'] })

      anchors.each do |node|
        if (link = resolved[node['href']])
          node['href'] = link.path
          references << link.target
        elsif (rewritten = internal_page_href(node['href']))
          node['href'] = rewritten
        end
      end

      fragment.css('img').each { |node| rewrite_image(node) }

      # Dedup: two links to the same note yield one Reference row (the DB unique index
      # is the second line of defense). An UNRESOLVED lalabase:// link contributes
      # nothing here — its href is left untouched and the sanitizer drops the unknown
      # scheme, so "not found", "wrong project" and "wrong tenant" look identical.
      [fragment.to_html, references.uniq]
    end

    # A relative link to another .md file becomes an in-app documentation link
    # to that page inside the same set. Anchors, absolute and non-.md links are
    # left untouched.
    def internal_page_href(href)
      return nil if href.blank? || absolute_or_anchor?(href)

      target, anchor = href.split('#', 2)
      return nil unless MARKDOWN_EXTENSIONS.include?(File.extname(target).downcase)

      resolved = resolve_relative(target)
      return nil if resolved.nil?

      path = routes.organisation_project_documentation_index_path(
        organisation_id: @documentation_set.project.organisation_id,
        project_id: @documentation_set.project_id,
        set_id: @documentation_set.id,
        page: resolved
      )
      anchor.present? ? "#{path}##{anchor}" : path
    end

    # An image is shown from the instance, or it is not shown as an image:
    #   * data: carries its bytes itself and stays;
    #   * a foreign address would make every reader's browser fetch it from there, so it
    #     becomes a link, a request only on a click;
    #   * a relative one gets the address the resolver gives, or shows as its alt text.
    def rewrite_image(node)
      src = node['src'].to_s.strip
      return if src.start_with?('data:')

      if src.start_with?('http://', 'https://', '//')
        replace_image(node, foreign_image_link(node, src))
      elsif (address = asset_address(src))
        node['src'] = address
      else
        replace_image(node, image_text(node, src))
      end
    end

    def asset_address(src)
      path = repository_path(src)
      path && @asset_resolver&.address_for(path)
    end

    # The file an image source names, as a path from the root of the REPOSITORY (an image
    # often lives beside the documentation folder, not in it), or nil when the source
    # names none or climbs out of the repository. A leading slash means the root of the
    # repository, as it does on the repository host. Query string and fragment are not
    # part of a file name; percent escapes are.
    def repository_path(src)
      file = src.split(/[?#]/, 2).first.to_s
      return nil if file.blank? || file.match?(/\A[a-z][a-z0-9+.-]*:/i)

      file = URI.decode_uri_component(file)
      base = file.start_with?('/') ? Pathname.new('.') : page_directory_in_repository
      candidate = (base + file.delete_prefix('/')).cleanpath.to_s
      return nil if candidate.start_with?('..', '/') || candidate == '.'

      candidate
    rescue ArgumentError
      nil
    end

    def page_directory_in_repository
      Pathname.new(@documentation_set.path_prefix.to_s) + Pathname.new(@page_path).dirname
    end

    def foreign_image_link(node, src)
      Nokogiri::XML::Node.new('a', node.document).tap do |link|
        link['href'] = src
        link.content = node['alt'].presence || src
      end
    end

    def image_text(node, src)
      Nokogiri::XML::Node.new('em', node.document).tap do |text|
        text.content = node['alt'].presence || File.basename(src.split(/[?#]/, 2).first.to_s)
      end
    end

    # An image that already sits in a link (a badge that links to its build) gives its
    # text to that link: a link inside a link is not HTML.
    def replace_image(node, replacement)
      if node.ancestors('a').any?
        node.replace(Nokogiri::XML::Text.new(replacement.content, node.document))
      else
        node.replace(replacement)
      end
    end

    def absolute_or_anchor?(value)
      value.start_with?('#', 'http://', 'https://', 'mailto:', 'data:', '//')
    end

    # Resolves lalabase:// knowledge links against THIS set's project + tenant.
    # Memoised: one instance per page render, reused across every anchor.
    def knowledge_link_resolver
      @knowledge_link_resolver ||= KnowledgeLinkResolver.new(documentation_set: @documentation_set)
    end

    # Normalises a link/image target relative to the current page's directory and
    # returns it, or nil if it escapes the set.
    #
    # The markdown comes from an EXTERNAL repo we do not control, so a target like
    # "../../../etc/passwd" must never be turned into an in-app link or a raw repo
    # URL pointing outside the synced folder. When cleanpath still leaves a leading
    # ".." or "/", we bail out (nil) and leave the original href/src untouched for
    # the sanitizer to handle — a broken link is fine, a traversal is not.
    def resolve_relative(relative)
      base_dir = Pathname.new(@page_path).dirname
      candidate = (base_dir + relative).cleanpath.to_s
      return nil if candidate.start_with?('..') || candidate.start_with?('/')

      candidate
    end

    # Rails' sanitize + path helpers live on view/controller helpers; we reach
    # them here because this renderer runs in a background job, outside any view.
    def sanitizer
      ActionController::Base.helpers
    end

    def routes
      Rails.application.routes.url_helpers
    end
  end
end
