# frozen_string_literal: true

# Where a help link goes. ONE owner, because the answer differs per instance:
# ours carries the handbook, a self-hosted one does not and links to the public
# documentation instead (doc/docs_delivery_plan.md, D4).
#
# Every help link outside app/views/help goes through here. A second
# hand-written one would be the one that keeps pointing at a page this instance
# cannot serve.
module HelpLinksHelper
  # Does this instance have the handbook itself?
  def help_available?
    Docs::Catalogue.available?
  end

  # The help start page, here or out there. In a request I18n.locale is the
  # reader's language, so the views need not carry it around; Docs::HelpLink
  # takes it as an argument because its other caller renders outside a request.
  def help_home_url
    Docs::HelpLink.home_url(locale: I18n.locale)
  end

  # One page, here or out there. The anchor comes without its hash, as Rails'
  # url helpers take it.
  def help_page_url(slug, anchor: nil)
    Docs::HelpLink.url(slug: slug, locale: I18n.locale, anchor: anchor)
  end
end
