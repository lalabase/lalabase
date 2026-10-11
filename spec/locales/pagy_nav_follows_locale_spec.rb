# frozen_string_literal: true

require 'rails_helper'

# Pagy renders its own strings, not ours: the nav's aria labels come from
# Pagy::I18n, not from config/locales.
#
# Without `pagy/extras/i18n` loaded, Pagy::Frontend#pagy_t reads @pagy_locale,
# which nothing ever sets, and Pagy::I18n then falls back to the FIRST language
# loaded in config/initializers/pagy.rb. That is 'de'. The result was a German
# pagination bar inside an English interface, on every screen that renders
# pagy_nav -- and I18n.locale had no influence at all.
#
# This lives in spec/locales because that whole directory runs in CI, and the
# defect is invisible in any single-language example.
RSpec.describe 'Pagy nav follows I18n.locale' do
  include Pagy::Frontend

  # The label of the nav element itself. Any Pagy key would do; this one appears
  # on every rendered bar.
  let(:nav_label_key) { 'pagy.aria_label.nav' }

  def label_in(locale)
    I18n.with_locale(locale) { pagy_t(nav_label_key, count: 3) }
  end

  it 'answers German in a German interface' do
    expect(label_in(:de)).to eq('Seiten')
  end

  it 'answers English in an English interface' do
    # The one that was broken. Asserted against the concrete word rather than
    # "differs from German", because a fallback that returns the KEY would also
    # differ.
    expect(label_in(:en)).to eq('Pages')
  end

  it 'both languages are actually loaded, not falling back to one another' do
    expect(label_in(:de)).not_to eq(label_in(:en))
  end
end
