# frozen_string_literal: true

# Pagy initializer for pagination.
#
# WHY THIS RUNS IN TEST TOO. It used to be wrapped in `unless Rails.env.test?`,
# with a stub Frontend below that answered '' for pagy_nav and '#' for
# pagy_url_for. Every pagination spec in the suite therefore asserted against a
# hash sign: the URL builder was never executed in a test, and neither was the
# overflow setting. Three defects lived behind that for months, including a 500
# on page ONE of /admin/accounts as soon as a 26th account existed. A pagination
# test that cannot fail is worse than none, because it reads as coverage.
require 'pagy'

# Pagy 9 reads these from Pagy::DEFAULT.
Pagy::DEFAULT[:limit] = 25 # Default page size
Pagy::DEFAULT[:size] = 10  # Number of links in the pagination bar
Pagy::DEFAULT[:overflow] = :last_page # Past the last page -> answer with the last one

# Load the required extras.
#
# ORDER MATTERS and has bitten us: `limit` sets DEFAULT[:limit_param] = :limit
# itself, so a `limit_param` assigned ABOVE this block is silently overwritten.
# It used to say :items up there and had no effect at all -- see the closing
# note at the bottom of this file.
#
# i18n is loaded so that pagy_nav follows I18n.locale. Without it @pagy_locale
# stays nil forever and Pagy::I18n falls back to the FIRST loaded language, so
# an English interface rendered a German pagination bar. Pinned by
# spec/locales/pagy_nav_follows_locale_spec.rb.
extras = %w[
  limit
  overflow
  countless
  headers
  trim
  i18n
]

extras.each do |extra|
  require "pagy/extras/#{extra}"
rescue LoadError => e
  Rails.logger.warn "Pagy: Konnte Extra '#{extra}' nicht laden - #{e.message}"
end

# I18n -- load all available locales
begin
  Pagy::I18n.load({ locale: 'de' }, { locale: 'en' })
rescue StandardError => e
  Rails.logger.warn "Pagy: Konnte die Uebersetzungen nicht laden - #{e.message}"
end

# A page number below 1 is a 500, and the overflow extra does NOT catch it.
#
# That extra only rescues Pagy::OverflowError -- "past the last page". A page
# of 0, -1 or "abc" raises Pagy::VariableError instead ("expected :page >= 1"),
# which nothing handles. Measured on /admin/accounts: `?page=0` and `?page=abc`
# both raised. Reachable by anyone editing the address bar, and by any crawler
# that walks a pagination link and decrements.
#
# PREPENDED ONTO Pagy::Backend rather than fixed in a controller: Pageable
# already clamps this for the controllers that use it (`[page.to_i, 1].max`),
# and the ones that call pagy() directly -- Admin::AccountsController is one --
# do not. Two implementations of the same rule, one of them missing, is the
# "same rule enforced by hand" signal from CLAUDE.md. One place, every caller.
module PagySafePage
  private

  # to_i, so "abc" becomes 0 and then 1. Deliberately NOT an argument error: a
  # nonsense page is a typo or a crawler, and page 1 is the answer a human
  # wants. Too LARGE a page stays with the overflow extra, which answers with
  # the last page.
  #
  # force_integer: false is passed through untouched. It is the jsonapi extra's
  # way of asking for the RAW param, and clamping it there would hand back an
  # Integer where a String is expected. Unused here, but silently changing the
  # contract of a method we only override is how the next upgrade breaks.
  def pagy_get_page(vars, force_integer: true)
    page = super
    return page unless force_integer

    [page.to_i, 1].max
  end
end

Pagy::Backend.prepend(PagySafePage)

# KNOWN, NOT FIXED HERE: the page-size URL parameter is `limit`, not `items`.
#
# This file used to set `Pagy::DEFAULT[:limit_param] = :items` above the extras
# block, where `pagy/extras/limit` overwrites it with :limit. So `?items=50`
# steers nothing and `?limit=50` does -- while the app builds `?items=N` links
# (PaginationHelper#pagination_items_url, shared/_pagination_nav.html.erb) and
# neo_pagination_controller.js parses for an items parameter.
#
# Second half of the same knot: `items:` is not a Pagy 9 variable either, so
# `pagy(scope, items: 20)` silently yields the default. Five controllers do that
# (smart_folders, user_activities, projects/activities, time_sessions,
# admin/email_logs).
#
# Deliberately left alone: fixing it changes the page size on live screens and
# touches those five callers plus the JS, which is its own pass. The dead
# assignment is removed rather than left looking effective, so nobody builds on
# it. Recorded because a silent wrong page size is not visible from the outside.
#
# Also removed as dead: DEFAULT[:params] (the app's own pagy_url_for never reads
# it) and DEFAULT[:enable_anchor] (not a Pagy 9 key).
