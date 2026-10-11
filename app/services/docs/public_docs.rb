# frozen_string_literal: true

# Where the public documentation lives, for every link this application sends
# a reader to: the help surface when it has no catalogue, the contextual
# drawer on an instance without one, and any page the catalogue does not hold.
#
# ONE owner, because these links are the entire help of a self-hosted
# instance. A second hand-built address somewhere would be the one that rots.
#
# Entry point: .url
module Docs
  module PublicDocs
    HOST = 'lalabase.com'

    module_function

    # An address on the public documentation. The host is fixed rather than
    # configurable: an instance links to OUR documentation, which is the only
    # one that exists, and nothing here would know another one's address.
    def url(locale: Contract::DEFAULT_LOCALE, slug: nil, anchor: nil)
      locale = Contract.locale_or_default(locale)
      path = slug.present? ? "/docs/#{locale}/#{slug}" : "/docs/#{locale}"
      fragment = anchor.presence && "##{anchor.to_s.delete_prefix('#')}"
      "https://#{HOST}#{path}#{fragment}"
    end
  end
end
