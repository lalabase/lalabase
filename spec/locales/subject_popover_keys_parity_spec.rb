# frozen_string_literal: true

require 'rails_helper'

# The app-wide fallback (config/initializers/i18n.rb, fallbacks = [:de]) makes
# a missing English key silent: the English page renders German and nothing
# goes red. The existing locale guards do not see that either (they compare
# values, not presence). This pins the capture popover's scope key-for-key in
# BOTH directions: deleting or adding a key on one side only fails here.
RSpec.describe 'subject_popover locale parity' do
  let(:scope) { 'views.organisations.time_sessions.subject_popover' }

  def keys_for(locale)
    tree = I18n.t(scope, locale: locale, fallback: false)
    expect(tree).to be_a(Hash), "#{locale}: #{scope} is missing entirely"
    tree.keys.sort
  end

  it 'carries the same keys in German and English, each with a present value' do
    de_keys = keys_for(:de)
    en_keys = keys_for(:en)
    expect(en_keys).to eq(de_keys)

    de_keys.each do |key|
      %i[de en].each do |locale|
        expect(I18n.t("#{scope}.#{key}", locale: locale, fallback: false))
          .to be_present, "#{locale}: #{scope}.#{key} is blank"
      end
    end
  end
end
