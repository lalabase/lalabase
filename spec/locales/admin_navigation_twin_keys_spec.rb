# frozen_string_literal: true

require 'rails_helper'

# Guard: every entry of the admin navigation exists under BOTH i18n namespaces,
# in BOTH locales.
#
# Why this exists (the drift it prevents):
# app/views/admin/common/_navigation.html.erb renders each menu entry TWICE --
# once in the desktop dropdown and once in the mobile menu -- and the two halves
# read DIFFERENT keys for the same label:
#
#   desktop: t('.accounts')                      -> admin.common.navigation.accounts
#   mobile:  t('views.admin.navigation.accounts') -> views.admin.navigation.accounts
#
# They also live in different FILES (config/locales/de.yml vs
# config/locales/views.de.yml). Adding an entry to only one of them builds a menu
# item that half the usage never sees, and nothing fails: the missing half simply
# renders "translation missing" on a viewport the author was not looking at.
# doc/billing_rechnungsstellung_r1_plan.md § 7 names this trap explicitly.
#
# Reads the loaded backend rather than I18n.t/I18n.exists?: with the en->de
# fallback configured, both answer for a key that exists only in German, which is
# exactly half of the drift this guard is meant to catch. A request spec cannot
# stand in for this either -- spec/requests/ does not run in the CI guard job.
RSpec.describe 'Admin navigation twin keys' do
  # The entries the partial renders in BOTH menus. Deliberately a literal list:
  # deriving it from the locale file would make the guard agree with whatever is
  # there, which is the opposite of a guard.
  #
  # The operator entries (accounts, billing_list, price_lists) are no twins any
  # more: they come in through a slot, and their partial renders BOTH menus from
  # one label (app/views/admin/operator/navigation/_management.html.erb).
  twin_entries = %w[
    dashboard organisations users
    system_settings ai_credentials
  ].freeze
  namespaces = [%i[admin common navigation], %i[views admin navigation]].freeze
  locales = %i[de en].freeze

  def stored(locale, *path)
    I18n.backend.send(:translations)[locale]&.dig(*path)
  end

  before { I18n.backend.send(:init_translations) unless I18n.backend.initialized? }

  locales.each do |locale|
    namespaces.each do |namespace|
      twin_entries.each do |entry|
        it "has #{locale}.#{namespace.join('.')}.#{entry}" do
          value = stored(locale, *namespace, entry.to_sym)

          expect(value).to be_present,
                           "missing #{locale}.#{namespace.join('.')}.#{entry} — the admin " \
                           'navigation renders this entry in two menus that read two ' \
                           'different namespaces; serving only one hides it on the other viewport'
        end
      end
    end

    # The point of the twins is that they say the SAME thing. Two labels drifting
    # apart is the quieter half of this bug: both menus work, and they disagree.
    twin_entries.each do |entry|
      it "says the same thing in both namespaces (#{locale}.#{entry})" do
        desktop = stored(locale, :admin, :common, :navigation, entry.to_sym)
        mobile = stored(locale, :views, :admin, :navigation, entry.to_sym)

        expect(desktop).to eq(mobile)
      end
    end
  end
end
