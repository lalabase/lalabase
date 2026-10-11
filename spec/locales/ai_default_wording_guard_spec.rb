# frozen_string_literal: true

require 'rails_helper'

# What: For the statement "the AI is switched off by default" there is ONE wording
#       per language.
# Why:  There were three, spread over twenty places: "ab Werk aus", "ab Werk
#       abgeschaltet", "im Auslieferungszustand aus", "bei Auslieferung abgeschaltet".
#       In English accordingly "off by default", "off as delivered", "switched off on
#       delivery".
#
#       That is not only untidy, it was wrong in two places. The German hero subtitle
#       said "Gehostet in Deutschland, KI ab Werk." (without the "aus", so the
#       opposite). The English one said "Hosted in Germany, AI included", right above
#       a ticker that claims "AI off by default".
#
#       Exactly this visitor, the one interested in data protection, is the one the
#       page wants.
#
#       The guard holds the state reached and does not claim completeness: it knows
#       the phrasings that EXISTED. It would not recognise a fourth one, but that one
#       could no longer arise from one of the old ones either.
ABGELOESTE_FORMELN = {
  de: ['ab Werk aus', 'ab Werk abgeschaltet', 'Auslieferungszustand', 'bei Auslieferung abgeschaltet'],
  en: ['off as delivered', 'switched off on delivery', 'switched off as delivered']
}.freeze

# Exactly one exception, and it means something else: the price badge says that
# the AI is included in the price, not that it is running.
ERLAUBT = ['badge: AI included'].freeze

RSpec.describe 'AI-default wording', type: :model do
  ABGELOESTE_FORMELN.each do |locale, formeln|
    it "uses one wording in #{locale}.yml" do
      zeilen = Rails.root.join('config/locales', "#{locale}.yml").readlines

      treffer = zeilen.each_with_index.filter_map do |zeile, index|
        next if ERLAUBT.any? { |ausnahme| zeile.include?(ausnahme) }
        next unless formeln.any? { |formel| zeile.include?(formel) }

        "Zeile #{index + 1}: #{zeile.strip[0, 110]}"
      end

      expect(treffer).to be_empty,
                         "Abgeloeste Formulierungen in #{locale}.yml:\n#{treffer.join("\n")}\n\n" \
                         "Es heisst #{locale == :de ? '„KI standardmäßig aus"' : '"AI off by default"'}."
    end
  end

  # The hero subtitle check stood here until W6. It belongs to the public pages
  # and is now checked over there (spec/locales/ai_default_wording_spec.rb in
  # gboyke/lalabase-website); what remains here is the scan over the texts of
  # the application itself.
end
