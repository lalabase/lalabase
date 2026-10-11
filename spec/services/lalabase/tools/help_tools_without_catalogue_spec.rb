# frozen_string_literal: true

require 'rails_helper'

# What: the three handbook tools on an instance that does not carry the handbook.
#
# Why:  that is every self-hosted instance, by decision. A tool that can only
#       fail teaches a model to keep trying, and the old failure message said
#       the help "may still be loading", which there is permanently untrue.
RSpec.describe 'help tools without a catalogue' do
  describe Lalabase::Tools::Registry do
    it 'drops them when there is none, in both sets that carry them' do
      # Only these two: the MCP set never carried the handbook tools, so asking
      # it would pass without the subtraction and read like coverage.
      without_docs_catalogue do
        %i[assistant assistant_with_code].each do |set|
          expect(described_class.for(set)).not_to include(*described_class::HELP_TOOLS)
        end
      end
    end

    it 'has the handbook tools in both of those sets to begin with' do
      %i[assistant assistant_with_code].each do |set|
        expect(described_class.for(set)).to include(*described_class::HELP_TOOLS)
      end
    end

    it 'keeps every other tool, so this narrows the set and does not empty it' do
      without_docs_catalogue do
        remaining = described_class.for(:assistant)

        expect(remaining).not_to be_empty
        expect(remaining).to include(Lalabase::Tools::GetTicket)
      end
    end
  end

  describe Lalabase::Tools::HelpTool do
    it 'says the handbook is not here, and where it is' do
      without_docs_catalogue do
        result = described_class.unavailable

        expect(result.error).to include('does not carry the handbook')
        expect(result.error).to include('https://lalabase.com/docs/de')
        expect(described_class.unavailable(locale: 'en').error).to include('https://lalabase.com/docs/en')
        expect(result.error).not_to include('still be loading')
      end
    end

    it 'keeps the loading message for the narrow case of an empty index' do
      # A catalogue exists, so the index will fill. Telling the model to wait is
      # true here and false in the case above; the two must not share a message.
      expect(described_class.unavailable.error).to include('still be loading')
    end
  end
end
