# frozen_string_literal: true

require 'rails_helper'

# The global persona pool is reference data: db/seeds/prompt_personas.rb writes
# it, and the file is meant to be re-run standalone on a server (it does NOT run
# on deploy). Two contracts live only in that file and nowhere else in the test
# suite: the run is idempotent, and the neutral row lands the way the model's
# NEUTRAL_KEY exception expects it: global, active, labelled, with NO fragment.
RSpec.describe 'db/seeds/prompt_personas.rb' do
  let(:seed_file) { Rails.root.join('db/seeds/prompt_personas.rb') }

  # `load` re-assigns the top-level GLOBAL_PROMPT_PERSONAS constant on every run.
  # That is a warning, not an error, and it is exactly what "runnable standalone"
  # means; the second run is the point of the first example.
  def run_seed
    silence_warnings { load seed_file }
  end

  def global_pool
    PromptPersona.where(organisation_id: nil).order(:key)
                 .pluck(:key, :system, :active, :position, :labels, :prompt_fragments)
  end

  it 'is idempotent: a second run adds no rows and changes none' do
    run_seed
    expect { run_seed }.not_to(change { global_pool })
  end

  it 'seeds the neutral row global, active, labelled and WITHOUT a fragment' do
    run_seed
    neutral = PromptPersona.find_by!(organisation_id: nil, key: PromptPersona::NEUTRAL_KEY)
    expect(neutral).to be_active
    expect(neutral.label('de')).to eq('Neutral')
    expect(neutral.label('en')).to eq('Neutral')
    expect(neutral.prompt_fragment('de')).to be_nil
    expect(neutral.prompt_fragment('en')).to be_nil
  end

  # Every seeded row is undeletable, and the neutral row is the one with the
  # sharpest reason: the app reads its key, and both carrying columns nullify on
  # delete, so losing it would silently turn every "no direction" choice into the
  # default. Retiring one stays possible through active: false; only destroying is
  # shut. A row that stops being system here is a row somebody can delete out from
  # under a stored choice.
  it 'seeds every row undeletable, the neutral opt-out included' do
    run_seed
    expect(PromptPersona.where(organisation_id: nil).pluck(:system)).to all(be(true))
  end

  # The pair to the line above, on the model rather than the data: the flag is not
  # decoration, it is what refuses the destroy.
  it 'refuses to destroy the neutral row' do
    run_seed
    neutral = PromptPersona.find_by!(organisation_id: nil, key: PromptPersona::NEUTRAL_KEY)

    expect(neutral.destroy).to be(false)
    expect(PromptPersona.exists?(neutral.id)).to be(true)
  end

  # ... and the escape hatch that makes the one-way door acceptable: an operator
  # who wants it out of the picker can still retire it. Only `overview` is barred
  # from that (guaranteed_default_stays_active).
  it 'still allows the neutral row to be retired' do
    run_seed
    neutral = PromptPersona.find_by!(organisation_id: nil, key: PromptPersona::NEUTRAL_KEY)

    expect(neutral.update(active: false)).to be(true)
  end
end
