# frozen_string_literal: true

# Where a link written in a docs page points (D8, doc/in_app_hilfe_plan.md).
# Entry point: .target
module Docs
  # Authors write links RELATIVE to the page ("tickets", "../basics/tickets#status") or in the
  # canonical form ("/docs/de/<slug>"). The reader that needs to know which page such a link
  # addresses is the assistant's get_help_page, which hands a page's Markdown to a language
  # model (doc/product_knowledge_plan.md, S2).
  #
  # Until D5 the second reader was this application's own Markdown renderer, and the two
  # shared this file so they could not resolve the same link to two different pages. The
  # renderer now lives in gboyke/lalabase-documentation and has its own copy of this module.
  #
  # ⚠️ Nothing in the code keeps the two copies in step: there is no shared library and no
  # Docs::Contract over there. What catches a divergence is the recorded catalogue --
  # docs_catalogue_format_spec.rb checks that the internal links in the HTML that program
  # really wrote match the shape THIS side resolves. So a changed shape shows up at the next
  # fixture refresh rather than as help pages whose links quietly stop working.
  module PageLinks
    # Everything with a scheme (http:, https:, mailto:, …) or protocol-relative → external.
    EXTERNAL_LINK_REGEX = %r{\A(?:[a-z][a-z0-9+.-]*:|//)}i

    module_function

    # [slug, anchor] for a link that addresses a docs page, nil for everything else: external,
    # a pure anchor, another app path (/pricing). The anchor keeps its "#", or is nil.
    def target(link, base_slug:)
      link = link.to_s
      return nil if link.blank? || link.start_with?('#') || link.match?(EXTERNAL_LINK_REGEX)
      return resolve_relative(link, base_slug.to_s) unless link.start_with?('/')

      match = link.match(Contract::CANONICAL_DOCS_REGEX)
      match && [match[1].chomp('/'), match[2]]
    end

    # Resolves a page-relative link against the directory of the page's own slug, with the
    # semantics a browser would apply.
    def resolve_relative(link, base_slug)
      path, anchor = link.split('#', 2)
      segments = base_slug.split('/')[0..-2] # page directory
      path.to_s.split('/').each do |segment|
        case segment
        when '', '.' then next
        when '..' then segments.pop
        else segments << segment
        end
      end
      [segments.join('/'), anchor ? "##{anchor}" : nil]
    end
    private_class_method :resolve_relative
  end
end
