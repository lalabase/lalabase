# frozen_string_literal: true

require 'rails_helper'

# Guards the AI action price list (decision 7A/9A). A metered action must never
# ship half-defined: every registry action needs a POSITIVE credit price and a
# label in BOTH locales, and the credit computation must never yield 0. This
# breaks the build the moment someone adds an action without its price/labels —
# the "new action without price" failure mode (plan §13) becomes impossible.
RSpec.describe Lalabase::Llm::ActionRegistry do
  describe 'registry completeness' do
    it 'defines at least the expected metered actions' do
      expect(described_class.keys).to include(
        'chat_message', 'semantic_search', 'document_indexing', 'summary', 'post_ai'
      )
    end

    described_class::ACTIONS.each_key do |action|
      context "action '#{action}'" do
        it 'has a positive base credit price' do
          expect(described_class::ACTIONS[action][:credits]).to be > 0
        end

        # I18n.exists? follows the fallback chain (en → de, config/initializers/
        # i18n.rb), so a deleted EN label still reported true while English users
        # silently saw German — the same structural blindness the feature-registry
        # guard fixed (adversarial review B2). Read each locale tree directly.
        it 'has a German label' do
          I18n.backend.eager_load!
          expect(I18n.backend.translations.dig(:de, :shared, :ai, :actions, action.to_sym)).to be_present
        end

        it 'has an English label — really in :en, not via the de fallback' do
          I18n.backend.eager_load!
          expect(I18n.backend.translations.dig(:en, :shared, :ai, :actions, action.to_sym)).to be_present
        end

        it 'never costs 0 credits, even for a minimal call' do
          expect(described_class.credits_for(action, tokens: 0)).to be >= 1
          expect(described_class.credits_for(action, tokens: 1)).to be >= 1
        end
      end
    end
  end

  describe '.credits_for' do
    it 'returns the flat price for a flat action regardless of tokens' do
      expect(described_class.credits_for('chat_message', tokens: 999_999)).to eq(2)
      expect(described_class.credits_for('chat_message', tokens: 0)).to eq(2)
    end

    it 'ceils a token-metered action per started block, floored at one block' do
      # document_indexing: 1 credit per started 1000 tokens
      expect(described_class.credits_for('document_indexing', tokens: 1)).to eq(1)
      expect(described_class.credits_for('document_indexing', tokens: 1_000)).to eq(1)
      expect(described_class.credits_for('document_indexing', tokens: 1_001)).to eq(2)
      expect(described_class.credits_for('document_indexing', tokens: 2_500)).to eq(3)
    end

    it 'raises on an unknown action (test 14 backstop)' do
      expect { described_class.credits_for('does_not_exist') }
        .to raise_error(described_class::UnknownActionError)
    end
  end
end
