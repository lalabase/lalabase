# frozen_string_literal: true

# What: AiSyncStatusHelper — the drawing table behind the Indexierung page's type cards.
# Type: Helper guard, derived from Embeddings::ContentTypes.
# Why:  The view iterates the registry and asks the helper for label, icon and colour. A
#       key the helper does not know must be a red test, not a blank card — and a label
#       that exists only in German would render fine and fall back silently
#       (config/initializers/i18n.rb sets fallbacks = [:de]), so both locales are asked
#       WITHOUT fallback.
# Contract: presentation for every registry key, a DE and an EN label for every key,
#   KeyError for an unknown key.
require 'rails_helper'

RSpec.describe AiSyncStatusHelper, type: :helper do
  it 'knows how to draw every registered content type' do
    expect(described_class::TYPE_PRESENTATION.keys).to match_array(Embeddings::ContentTypes.keys)
  end

  it 'has a label for every registered type in BOTH locales, without fallback' do
    Embeddings::ContentTypes.entries.each do |entry|
      %i[de en].each do |locale|
        expect(I18n.exists?("views.organisations.ai_sync_statuses.show.types.#{entry.key}", locale, fallback: false))
          .to be(true), "#{locale}: #{entry.key}"
      end
    end
  end

  it 'gives every type an icon and the three class strings the view places' do
    described_class::TYPE_PRESENTATION.each_value do |presentation|
      expect(presentation.keys).to contain_exactly(:icon, :card, :heading, :bar)
      expect(presentation.values).to all(be_present)
    end
  end

  it 'refuses an unknown key rather than rendering a blank card' do
    expect { helper.ai_sync_type_presentation(:documents) }.to raise_error(KeyError)
  end
end
