# frozen_string_literal: true

require 'rails_helper'

# Task-0 measurement harness for the LLM detection leg (Gespräche Slice 5,
# plan §9 question 1): drives the service's EXACT prompt + parse path
# (system_prompt / MAX_TOKENS / TEMPERATURE / parse_participants) against the 5
# committed transcript fixtures and scores micro-F1 against the README ground
# truth. The offline parser passed its own spike gate in Slice 1b (100%
# micro-F1); this harness answers the same question for the LLM leg.
#
# NEVER runs in CI or a default `rspec`: excluded via
# `filter_run_excluding llm_live` (rails_helper) and additionally skipped
# without an API key. Run the live measurement with:
#
#   LLM_LIVE=1 OPENAI_API_KEY=sk-... bundle exec rspec \
#     spec/services/meetings/participant_detection_live_spec.rb
#
# The provider is built directly from the env key (no organisation, no quota
# gate, no usage tracking) — this measures prompt quality, not gating.
RSpec.describe Meetings::ParticipantDetectionService, :llm_live do
  # README ground truth (spec/fixtures/meeting_transcripts/README.md), compared
  # on normalize_name keys so spelling variance never skews the score.
  let(:ground_truth) do
    {
      'fixture_01_vollnamen_frontmatter.md' => ['Anna Ananas', 'Bert Bauer', 'Karl Krause'],
      'fixture_02_vornamen_ohne_frontmatter.md' => %w[Anna Bert Karl],
      'fixture_03_speaker_suffixe.md' => ['Karl Krause', 'Anna Ananas', 'Bert Bauer'],
      'fixture_04_namens_normalisierung.md' => ['Karl Krause', 'Bert Bauer', 'Anna Ananas'],
      'fixture_05_fallstricke.md' => ['Bert Bauer', 'Karl Krause']
    }
  end

  let(:target_micro_f1) { 0.9 }

  # The measurement model lives HERE, not on the service: since S1
  # (doc/ki_provider_reichweite_plan.md) the service passes no model at all and
  # follows the org's chat provider. This harness measures PROMPT quality, which
  # is only comparable against a fixed model — so it pins one deliberately.
  let(:measurement_model) { 'gpt-4o-mini' }

  it 'reaches >= 90% micro-F1 against the fixture ground truth' do
    api_key = ENV['OPENAI_API_KEY'].presence
    skip 'OPENAI_API_KEY not set — run the harness manually (see file header)' unless api_key

    provider = Lalabase::Llm::OpenAiProvider.new(api_key: api_key)
    tp = fp = fn = 0

    ground_truth.each do |file, expected|
      transcript = Rails.root.join('spec/fixtures/meeting_transcripts', file).read
      response = provider.chat(
        messages: [
          { role: 'system', content: described_class.system_prompt },
          { role: 'user', content: transcript }
        ],
        model: measurement_model,
        max_tokens: described_class::MAX_TOKENS,
        temperature: described_class::TEMPERATURE
      )
      detected = described_class.parse_participants(response[:content])
      expect(detected).not_to be_nil, "#{file}: unparseable LLM answer: #{response[:content].inspect}"

      detected_keys = detected.map { |n| MeetingParticipant.normalize_name(n) }.to_set
      expected_keys = expected.map { |n| MeetingParticipant.normalize_name(n) }.to_set

      tp += (detected_keys & expected_keys).size
      fp += (detected_keys - expected_keys).size
      fn += (expected_keys - detected_keys).size
      puts "#{file.ljust(45)} detected: #{detected.join(', ')}"
    end

    precision = tp.zero? ? 0.0 : tp.to_f / (tp + fp)
    recall = tp.zero? ? 0.0 : tp.to_f / (tp + fn)
    f1 = (precision + recall).zero? ? 0.0 : 2 * precision * recall / (precision + recall)
    puts "micro-P=#{precision.round(3)}  micro-R=#{recall.round(3)}  " \
         "micro-F1=#{f1.round(3)}  (target >= #{target_micro_f1})"

    expect(f1).to be >= target_micro_f1
  end
end
