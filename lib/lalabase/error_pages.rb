# frozen_string_literal: true

require 'erb'

module Lalabase
  # Writes the four static error pages in public/ from one template
  # (error_pages/page.html.erb) and the texts under `error_pages` in
  # config/locales/error_pages.{de,en}.yml.
  #
  #   bin/rails runner script/error_pages
  #
  # Why static files and not a controller: two programs answer an error, and only
  # a file serves both. Rails' own exceptions app renders public/<status>.html
  # for a missing route, a missing record, an expired form or a crash, and the
  # browser gate (`allow_browser`) renders public/406-unsupported-browser.html.
  # When Puma does not answer at all (a deploy, a crash), only the web server is
  # left, and it can serve the same 500.html (`error_page 502 503 504 /500.html`).
  # A page that needs Rails to render cannot help in the one case Rails is gone.
  #
  # Until 2026-11-27 public/ was ignored as a whole and none of these files was
  # ever deployed: a wrong address answered 404 with an empty body.
  #
  # Each page is self-contained: its style is inline, its font comes from
  # public/fonts, it runs no script and names no other host. It shows German and
  # English one below the other, because a static file cannot know the visitor's
  # language. Guard: spec/architecture/public_error_pages_spec.rb.
  #
  # Entry point: write_all!
  module ErrorPages
    # File name in public/ => key under `error_pages`.
    PAGES = {
      '404' => :not_found,
      '422' => :unprocessable,
      '500' => :server_error,
      '406-unsupported-browser' => :unsupported_browser
    }.freeze

    # The first one sets the page's language; every one gets its own section.
    LOCALES = %i[de en].freeze

    TEMPLATE = File.expand_path('error_pages/page.html.erb', __dir__)

    module_function

    def write_all!
      PAGES.each_key { |name| File.write(path(name), render(name)) }
    end

    def path(name)
      Rails.public_path.join("#{name}.html")
    end

    # The page as it belongs in public/, for the given file name.
    def render(name)
      key = PAGES.fetch(name)
      code = name.to_i
      sections = LOCALES.map { |locale| section(key, locale) }
      home = LOCALES.map { |locale| I18n.t('error_pages.home', locale: locale) }

      ERB.new(File.read(TEMPLATE), trim_mode: '-').result_with_hash(
        lang: LOCALES.first, code: code, sections: sections, home: home,
        title: "#{code} · #{sections.map { |text| text[:title] }.join(' · ')}"
      )
    end

    def section(key, locale)
      %i[title heading text].index_with { |part| I18n.t("error_pages.#{key}.#{part}", locale: locale) }
                            .merge(locale: locale)
    end
  end
end
