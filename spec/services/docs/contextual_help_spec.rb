# frozen_string_literal: true

require 'rails_helper'

# What: Docs::ContextualHelp — the curated {context -> questions} map behind the
#       "?" contextual-help trigger (doc/kontexthilfe_plan.md).
# Type: Structure and translations only.
# Why:  This side owns the map. Whether its slugs and anchors match real headings
#       is a question about the TEXT, and the text lives in
#       gboyke/lalabase-documentation, which checks it with
#       `bin/rails "anchors:check[/path/to/this/checkout]"` over there. It used to
#       be checked here against a recording of the handbook, and that recording
#       carried the documentation into this repository, which is going open
#       source (doc/docs_delivery_plan.md, goal 1).
#
#       ⚠️ So a renamed heading over there is NOT caught by THIS file. Since
#       2026-09-22 it is caught in CI, in both directions: the documentation
#       repository runs that task against a checkout of this one on every change,
#       and .github/workflows/anchors.yml here runs it against a checkout of the
#       documentation whenever the map changes. Do not add an anchor check back
#       into this file without bringing the text with it.
RSpec.describe Docs::ContextualHelp do
  let(:questions) { described_class::QUESTIONS.values.flatten }

  it 'has questions to check, so the rules below are not passing on an empty map' do
    expect(described_class::QUESTIONS.size).to be > 10
    expect(questions.size).to be > 40
  end

  it 'gives every question a label that both languages translate' do
    %w[de en].each do |locale|
      questions.each do |question|
        expect { I18n.t!(question[:label_key], locale: locale) }
          .not_to raise_error, "#{question[:label_key]} has no #{locale} translation"
      end
    end
  end

  it 'gives every question a slug that looks like one' do
    questions.each do |question|
      expect(question[:slug]).to match(%r{\A[a-z0-9][a-z0-9/-]*\z})
      # Only the handbook is in the catalogue this application reads.
      expect(question[:slug]).to start_with('guides/')
    end
  end

  it 'gives an anchor, where it has one, a string per language' do
    # The map carries { de:, en: } because Redcarpet slugifies a translated
    # heading differently. One language missing means a dead deep link there.
    questions.filter_map { |question| question[:anchor] }.each do |anchor|
      expect(anchor.keys.sort).to eq(%i[de en])
      expect(anchor.values).to all(be_present)
    end
  end

  describe '.for' do
    it 'answers a context it knows, as a symbol or a string, and stays quiet otherwise' do
      expect(described_class.for(:tickets)).not_to be_empty
      expect(described_class.for('tickets')).to eq(described_class.for(:tickets))
      expect(described_class.for(:nothing_like_this)).to eq([])
    end
  end

  describe '.anchor_for' do
    it 'resolves per language and answers nil without an anchor' do
      with_anchor = questions.find { |question| question[:anchor] }

      expect(described_class.anchor_for(with_anchor, :de)).to eq(with_anchor[:anchor][:de])
      expect(described_class.anchor_for({ slug: 'guides/x/y' }, :de)).to be_nil
    end
  end
end
