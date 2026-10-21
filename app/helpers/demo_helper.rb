# frozen_string_literal: true

# The way out of the public demo (Lalabase::Demo.website_url): one link, on the
# sign-in page and in the banner. Nil when the demo instance names no website.
module DemoHelper
  def demo_website_link(**options)
    url = Lalabase::Demo.website_url or return

    link_to t('views.demo.website.back', site: Lalabase::Demo.website_name), url, **options
  end
end
