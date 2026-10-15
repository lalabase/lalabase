# frozen_string_literal: true

require 'rails_helper'

# Guard: every billing interval in the registry has a label and a billing note,
# in BOTH locales. Since 2026-10-15 the same for every plan in
# `Subscriptions::Constants::PLAN_KEYS`: the billing-account view names the
# booked plan through a key built the same way.
#
# Why this exists (the drift it prevents):
# `Subscriptions::Constants::BILLING_INTERVALS` is a REGISTRY (D10). Two places
# say out loud that a third interval is a data change and needs no code change --
# the interval registry and `app/javascript/controllers/CLAUDE.md`. That is only
# true of the Ruby and the JavaScript: two screens build an I18n key per interval
# out of the registry, and a dynamic key is invisible to i18n-tasks, which only
# sees literal ones. Add `quarterly` and nothing fails -- the screen simply ships
# `translation missing: de...quarterly`.
#
# The billing-account view owns its labels under
# `views.billing_accounts.show.billing_interval`. The admin backend builds the
# same kind of key under its own `admin.billing_interval` scope, read by four
# places: the price-list forms, Actors::PublishPriceList#message_for, and the
# billing-state form of an account. The scope is deliberately NOT nested under
# any one of them -- it is shared vocabulary, and a name like
# `admin.price_lists.interval` would make the account form look as if it were
# reaching into the price-list screen.
#
# A third scope, `static.pricing.ladder.*`, was here until W6. It belonged to the
# public pricing page, which lives in gboyke/lalabase-website now and guards its
# own copy.
#
# Those call sites pass a `default:`, which only rescues the case where the key is
# missing in EVERY locale: with the en->de fallback configured, a key present in DE
# and forgotten in EN never reaches the default and shows an English-speaking
# operator German text instead. So both scopes need the both-locales guard.
#
# Reads the loaded backend rather than `I18n.exists?`: with the en->de fallback
# configured, `I18n.exists?(key, :en)` answers true for a key that exists only in
# German, which is exactly the drift this guard is meant to catch.
RSpec.describe 'Billing interval locale keys' do
  # Every I18n scope that builds keys from a registry, with the group it builds
  # underneath and the registry it reads. Adding a consumer means adding a line
  # here, not writing a second guard.
  key_sources = [
    { scope: %i[views billing_accounts show], groups: %i[billing_interval],
      registry: Subscriptions::Constants::BILLING_INTERVAL_KEYS },
    { scope: %i[admin], groups: %i[billing_interval], registry: Subscriptions::Constants::BILLING_INTERVAL_KEYS },
    { scope: %i[views billing_accounts show], groups: %i[plan], registry: Subscriptions::Constants::PLAN_KEYS }
  ].freeze
  locales = %i[de en].freeze

  # nil when absent -- never the fallback value of another locale.
  def stored(locale, *path)
    I18n.backend.send(:translations)[locale]&.dig(*path)
  end

  before { I18n.backend.send(:init_translations) unless I18n.backend.initialized? }

  key_sources.each do |source|
    scope = source[:scope]
    scope_label = scope.join('.')

    locales.each do |locale|
      source[:groups].each do |group|
        source[:registry].each do |entry|
          it "has #{locale}.#{scope_label}.#{group}.#{entry}" do
            value = stored(locale, *scope, group, entry.to_sym)

            expect(value).to be_present,
                             "missing #{locale}.#{scope_label}.#{group}.#{entry}: this key is built from " \
                             'a registry in Subscriptions::Constants'
          end
        end

        # The other half of the contract: a stale label for an entry that left
        # the registry is dead weight, and the next reader cannot tell it from a
        # live one.
        it "has no #{locale}.#{scope_label}.#{group} entry outside the registry" do
          stored_keys = (stored(locale, *scope, group) || {}).keys.map(&:to_s)

          expect(stored_keys).to match_array(source[:registry])
        end
      end
    end
  end
end
