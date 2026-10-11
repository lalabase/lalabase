# frozen_string_literal: true

# Deliberately only <loc>: <lastmod> would have to be invented for static
# views, and <priority>/<changefreq> have been ignored by every major crawler
# for a decade. An honest sitemap of eight URLs beats a decorated one.
#
# Builder rather than ERB on purpose: erblint is an HTML linter and reports the
# XML declaration of an .xml.erb template as an error on every run. A template
# format that needs no lint exception is better than a lint exception.
#
# Each page is listed once per language, and every entry repeats the full set of
# translations as xhtml:link alternates -- including a self-reference, which the
# specification requires. x-default points at German: it is the default locale and the
# language a visitor without a match should land in.
xml.instruct! :xml, version: '1.0', encoding: 'UTF-8'
xml.urlset(xmlns: 'http://www.sitemaps.org/schemas/sitemap/0.9',
           'xmlns:xhtml' => 'http://www.w3.org/1999/xhtml') do
  @pages.each do |alternates|
    alternates.each_value do |url|
      xml.url do
        xml.loc url
        alternates.each do |locale, alternate_url|
          xml.tag!('xhtml:link', rel: 'alternate', hreflang: locale, href: alternate_url)
        end
        xml.tag!('xhtml:link', rel: 'alternate', hreflang: 'x-default',
                               href: alternates[I18n.default_locale])
      end
    end
  end
end
