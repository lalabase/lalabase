# frozen_string_literal: true

# Local help page or public documentation? ONE owner for that decision, asked
# by the views (through HelpLinksHelper) and by the assistant's citations.
#
# It was two owners for a while, and they disagreed about the language: the
# views read I18n.locale, which is right in a request, while a citation is
# rendered again inside a streaming job where the ambient locale is the app
# default. A citation carries the language its page was read in, so the caller
# passes the language rather than letting this guess.
#
# Entry point: .url
module Docs
  module HelpLink
    module_function

    # One page. The anchor comes without its hash, as Rails' url helpers take it.
    def url(slug:, locale:, anchor: nil)
      return PublicDocs.url(locale: locale, slug: slug, anchor: anchor) unless Catalogue.available?

      routes.help_page_path(slug: slug, anchor: anchor)
    end

    # The help start page.
    def home_url(locale:)
      return PublicDocs.url(locale: locale) unless Catalogue.available?

      routes.help_path
    end

    def routes = Rails.application.routes.url_helpers
  end
end
