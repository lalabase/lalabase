# frozen_string_literal: true

# What this application needs about documentation after the engine left for
# gboyke/lalabase-documentation (doc/docs_delivery_plan.md, D4).
#
# These are not leftovers. Each one has a consumer OUTSIDE the engine that
# survives the move, and each used to live in a file that goes away at D5:
# the locales in a model validation, the search minimum in the help
# controller, the allowlist in a help view, the canonical href shape in the
# link rewriter and in the assistant's help reader.
#
# The other program renders with its own copy of the engine. The two only have
# to agree on the canonical href shape and on this allowlist; everything else
# arrives in the catalogue already decided.
#
# Entry point: .locale_or_default
module Docs
  module Contract
    LOCALES = %w[de en].freeze
    DEFAULT_LOCALE = 'de'

    # Below this a search term is not searched at all, so the list stays empty
    # while somebody types the first character instead of saying "no results".
    MIN_TERM_LENGTH = 2

    # What a reader sanitising the catalogue's HTML has to admit: the prose tags
    # plus everything the other program's renderer emits itself, which is the
    # code-block wrapper, Rouge token spans and heading anchors.
    #
    # ⚠️ This list and the one over there are two halves of one contract. A tag
    # emitted there but missing here disappears silently from the help, and the
    # reader sees a page with a hole in it rather than an error.
    ALLOWED_TAGS = %w[
      p br strong em del code pre span div button ul ol li blockquote a img
      h1 h2 h3 h4 h5 h6 hr table thead tbody tr th td
    ].freeze
    ALLOWED_ATTRIBUTES = %w[href title lang src alt class id type aria-label].freeze

    # The href shape the other program writes into its HTML, and the only thing
    # the two renderers have to agree on besides the allowlist above.
    #
    # It lives here rather than in Docs::PageLinks, which was expected to go away
    # at D5 and did not: the assistant resolves the links in a page's Markdown
    # through it. So PageLinks reads this one instead of keeping the second copy
    # that prediction had justified.
    CANONICAL_DOCS_REGEX = %r{\A/docs/(?:#{LOCALES.join('|')})/([^#?]+)(#.*)?\z}

    module_function

    def locale_or_default(locale)
      locale.to_s.presence_in(LOCALES) || DEFAULT_LOCALE
    end
  end
end
