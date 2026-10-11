# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::HelpContents -- every page of Lalabase's own help with its slug,
#       title, section and description (doc/product_knowledge_plan.md, S2, D7).
# Type: Service spec: the table as given for the behaviour, the real help for the size guard.
# Why:  The model chooses a page by meaning from this list, so it must hold every page of the
#       asker's language, bring a page without a translation in German and say so, cite
#       nothing (the page read next is the source), answer "not available" on an empty table,
#       and stay small: it costs tokens on every call, and the plan names that as a risk.
RSpec.describe Lalabase::Tools::HelpContents do
  let(:organisation) { create(:organisation) }
  let(:actor) { create(:user, language_preference: 'de') }
  let(:context) { Lalabase::Tools::Context.new(actor: actor, organisation: organisation) }

  def run
    described_class.execute(args: {}, context: context)
  end

  it 'is a read tool without arguments that needs the asker, for the language' do
    expect(described_class.mutating?).to be false
    expect(described_class.requires_actor?).to be true
    expect(described_class.input_schema).to eq(type: 'object', properties: {})
  end

  describe 'with the table as given', :product_knowledge_table_as_given do
    it "lists every page of the asker's language: slug, title, section and description, no text" do
      create(:product_knowledge_entry, slug: 'guides/a/one', title: 'Eins', description: 'Die erste.')
      create(:product_knowledge_entry, slug: 'guides/a/two', title: 'Zwei', description: 'Die zweite.')
      create(:product_knowledge_entry, slug: 'guides/a/one', locale: 'en', title: 'One')

      expect(JSON.parse(run.content)['data']).to eq(
        [{ 'slug' => 'guides/a/one', 'title' => 'Eins', 'section' => 'Grundlagen', 'description' => 'Die erste.' },
         { 'slug' => 'guides/a/two', 'title' => 'Zwei', 'section' => 'Grundlagen', 'description' => 'Die zweite.' }]
      )
    end

    it 'brings a page without a translation in German, and says so on that page alone' do
      actor.update!(language_preference: 'en')
      create(:product_knowledge_entry, slug: 'guides/a/one', title: 'Eins')
      create(:product_knowledge_entry, slug: 'guides/a/one', locale: 'en', title: 'One')
      create(:product_knowledge_entry, slug: 'guides/a/two', title: 'Zwei')

      parsed = JSON.parse(run.content)

      expect(parsed['locale']).to eq('en')
      expect(parsed['data']).to eq(
        [{ 'slug' => 'guides/a/one', 'title' => 'One', 'section' => 'Grundlagen', 'description' => nil },
         { 'slug' => 'guides/a/two', 'title' => 'Zwei', 'section' => 'Grundlagen', 'description' => nil,
           'locale' => 'de' }]
      )
    end

    it 'cites nothing: the page the model reads next is the source' do
      create(:product_knowledge_entry)

      expect(run.citations).to eq([])
    end

    it 'says the help is not available on an empty table' do
      result = run

      expect(result).not_to be_success
      expect(result.error).to include('not available')
    end
  end

  # About 11,000 characters a language (under 3,000 tokens), measured when this was written.
  # The bound sits well above that, so a description that grew into a paragraph turns this red
  # instead of costing tokens quietly on every help question. The page count first, or an empty
  # list would pass the bound.
  %w[de en].each do |locale|
    it "lists every page of the real #{locale} help, and stays small" do
      actor.update!(language_preference: locale)
      pages = ProductKnowledge::Sources.rows.count { |row| row[:locale] == locale }

      content = run.content

      expect(JSON.parse(content)['data'].size).to eq(pages)
      expect(content.length).to be < 16_000
    end
  end
end
