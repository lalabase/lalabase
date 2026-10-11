# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::SearchHelp -- finds pages of Lalabase's own help by words
#       (doc/product_knowledge_plan.md, S2).
# Type: Service spec against the table as given (factory rows, EnsureFresh stubbed).
# Why:  The help has no rights, so what matters is everything else a search tool promises:
#       the asker's language rather than the chat's, and the result says which it is; the
#       fields the model chooses from; the first three hits cited and not all eight, none with
#       an area so the answer stays ungated; an empty answer that points at help_contents and
#       names the help's language; "not available" rather than "no match" while the table is
#       still empty; and, since the first real run, the way to the contents list named in every
#       result, because a hit can share a word and still miss the question.
RSpec.describe Lalabase::Tools::SearchHelp, :product_knowledge_table_as_given do
  let(:organisation) { create(:organisation) }
  let(:actor) { create(:user, language_preference: 'de') }
  let(:context) { Lalabase::Tools::Context.new(actor: actor, organisation: organisation) }

  def entry(title, locale: 'de', body: 'Text der Seite.', slug: nil)
    create(:product_knowledge_entry, title: title, locale: locale, body_text: body,
                                     slug: slug || "guides/test/#{title.parameterize}")
  end

  def run(query)
    described_class.execute(args: { q: query }, context: context)
  end

  describe 'contract metadata' do
    it 'is a read tool that needs the asker, for the language' do
      expect(described_class.mutating?).to be false
      expect(described_class.requires_actor?).to be true
      expect(described_class.input_schema[:required]).to eq(['q'])
    end

    # The instruction, not the sentence that justifies it: a description may be reworded, and
    # what has to survive is the condition together with the tool to call under it.
    it 'tells the model what to do when no hit fits the question' do
      expect(described_class.description).to include('when none of them fits, call help_contents')
    end
  end

  it 'returns what the model chooses from, and the language the help is read in' do
    entry('Zeit buchen', body: 'Zeit buchst du am Ticket.')

    parsed = JSON.parse(run('Zeit').content)
    data = parsed['data']

    expect(parsed['locale']).to eq('de')
    expect(data.first.keys).to contain_exactly('slug', 'title', 'section', 'description', 'snippet')
    expect(data.first).to include('slug' => 'guides/test/zeit-buchen', 'title' => 'Zeit buchen')
  end

  # language_preference, not chat.language: the detector answers "en" for "Zeit buchen".
  it "searches in the asker's language" do
    entry('Zeit buchen', slug: 'guides/features/time-tracking')
    entry('Tracking time', locale: 'en', slug: 'guides/features/time-tracking')
    actor.update!(language_preference: 'en')

    expect(JSON.parse(run('time').content)['data'].pluck('title')).to eq(['Tracking time'])
  end

  # The failure of the first real run (12.09.2026): three pages that merely shared a word, and
  # the model concluded the help had nothing and answered from its own knowledge. The way out is
  # named in EVERY result, the good one included: whether a hit answers the question is a
  # judgement about meaning, and the catalogue showed that no property of the hit predicts it
  # (question_catalogue_spec, "the match kind does not separate a good result from a bad one").
  it 'names the way to help_contents, whether the words landed or not' do
    entry('Farben', body: 'Eine Farbe je Organisation.')
    entry('Zeit buchen', body: 'Zeit buchst du am Ticket.')

    beside_the_point = JSON.parse(run('Kollegin einladen Organisation').content)
    on_the_point = JSON.parse(run('Zeit buchen').content)

    expect(beside_the_point['data']).to be_present
    expect(beside_the_point['next_step']).to include('help_contents')
    expect(on_the_point['next_step']).to eq(beside_the_point['next_step'])
  end

  it 'cites the first three hits in their order, each without an area, so the answer stays ungated' do
    5.times { |i| entry("Zeit Seite #{i}", body: 'Zeit buchen.') }

    result = run('Zeit')
    data = JSON.parse(result.content)['data']

    expect(data.size).to eq(5)
    expect(result.citations.pluck(:id)).to eq(data.first(described_class::MAX_CITATIONS).pluck('slug'))
    expect(result.citations).to all(include(type: 'help_page', source: 'help'))
    expect(Lalabase::Citations.areas_of(result.citations.map(&:deep_stringify_keys))).to be_empty
  end

  it 'cites every hit when there are fewer than three' do
    2.times { |i| entry("Zeit Seite #{i}", body: 'Zeit buchen.') }

    expect(run('Zeit').citations.size).to eq(2)
  end

  it 'answers an empty success that points at help_contents and names the help language' do
    entry('Zeit buchen')

    result = run('Rechnungsnummer')

    expect(result).to be_success
    expect(result).to be_empty
    expect(result.content).to include('help_contents').and include('"de"')
    expect(result.citations).to eq([])
  end

  # A fresh install while another process still syncs: "no help page matches" would be a
  # false statement the model passes on.
  it 'says the help is not available on an empty table, instead of "no match"' do
    result = run('Zeit')

    expect(result).not_to be_success
    expect(result.error).to include('not available')
  end

  it 'refuses a blank query' do
    expect(run('  ').error).to eq('q is required')
  end
end
