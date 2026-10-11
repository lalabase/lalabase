# frozen_string_literal: true

require 'rails_helper'

# The single number↔index derivation (chat_quellen_attribution_plan.md §6/§12).
# `.for/#number_for` is the forward map PromptBuilder uses to number context items;
# `.apply_used_flags` is the reverse the job uses to flag runner.citations from a
# parsed marker. Both encode "number = citation index + 1" in ONE place so they
# cannot drift. The flag application must NEVER drop/reorder/reshape a citation —
# only add `used:` — because the render-gate keeps reading the full list (§3).
RSpec.describe Lalabase::ProjectRag::SourceNumbering do
  describe '.for / #number_for — forward map' do
    let(:citations) do
      [{ type: 'vision', id: 'v1' },
       { type: 'capability', id: 'c1' },
       { type: 'ticket', id: 't1', area: 'tickets' }]
    end

    it 'numbers citations 1-based in list order' do
      numbering = described_class.for(citations)
      expect(numbering.number_for('vision', 'v1')).to eq(1)
      expect(numbering.number_for('capability', 'c1')).to eq(2)
      expect(numbering.number_for('ticket', 't1')).to eq(3)
    end

    it 'matches a Symbol type against a String-keyed citation (and vice versa)' do
      numbering = described_class.for([{ 'type' => 'ticket', 'id' => 't1' }])
      expect(numbering.number_for(:ticket, 't1')).to eq(1)
    end

    it 'returns nil for a citation not in the list' do
      expect(described_class.for(citations).number_for('note', 'n9')).to be_nil
    end

    it 'is inactive for an empty list (PromptBuilder then skips numbering entirely)' do
      expect(described_class.for([]).active?).to be(false)
      expect(described_class.for(nil).active?).to be(false)
      expect(described_class.for(citations).active?).to be(true)
    end
  end

  describe '.apply_used_flags — reverse mapping onto runner.citations' do
    # Two numbered citations (initial_count 2). The parse result decides which stay used.
    let(:citations) do
      [{ type: 'vision', id: 'v1' }, { type: 'ticket', id: 't1', area: 'tickets' }]
    end

    def flags_for(parse_result, list: citations, initial_count: 2)
      described_class.apply_used_flags(citations: list, initial_count: initial_count, parse_result: parse_result)
                     .map { |c| c[:used] }
    end

    it 'flags exactly the referenced numbers as used, the rest as not-used' do
      expect(flags_for({ marker_found: true, used_indices: [1] })).to eq([true, false])
      expect(flags_for({ marker_found: true, used_indices: [2] })).to eq([false, true])
    end

    it 'flags nothing as used for an explicit `none`' do
      expect(flags_for({ marker_found: true, used_indices: :none })).to eq([false, false])
    end

    it 'falls back to all-used when no marker was found (lossless — never worse than today)' do
      expect(flags_for({ marker_found: false, used_indices: [] })).to eq([true, true])
    end

    it 'falls back to all-used for a marker with an empty/garbled number list ([] is NOT :none)' do
      # parse distinguishes an explicit `none` (:none) from "marker present but no
      # valid number" ([]) — the latter must fall back, not hide every source.
      expect(flags_for({ marker_found: true, used_indices: [] })).to eq([true, true])
    end

    it 'falls back to all-used when the marker held ONLY out-of-range numbers' do
      # 5 and 9 exceed initial_count 2 → no valid number → fallback, NOT an empty set.
      expect(flags_for({ marker_found: true, used_indices: [5, 9] })).to eq([true, true])
    end

    it 'ignores an out-of-range number but honours the valid ones' do
      expect(flags_for({ marker_found: true, used_indices: [1, 9] })).to eq([true, false])
    end

    it 'defaults an append-only runtime tool citation (position ≥ initial_count) to used' do
      # The tool citation at index 2 was never numbered in the prompt — the model
      # could not mark it — so it is used by default (§6.2), regardless of the marker.
      list = citations + [{ type: 'symbol', id: 'tool_sym' }]
      expect(flags_for({ marker_found: true, used_indices: [1] }, list: list, initial_count: 2))
        .to eq([true, false, true])
    end

    it 'keeps a tool citation used even under an explicit `none`' do
      list = citations + [{ type: 'symbol', id: 'tool_sym' }]
      expect(flags_for({ marker_found: true, used_indices: :none }, list: list, initial_count: 2))
        .to eq([false, false, true])
    end

    it 'gives the SAME number to two fragments of one deduped ticket (shared source)' do
      # Two prompt items → one citation → both attributed by the single marker number.
      numbering = described_class.for([{ type: 'ticket', id: 't1', area: 'tickets' }])
      expect(numbering.number_for('ticket', 't1')).to eq(1) # both fragments resolve here
    end

    it 'does NOT mutate the input citations (returns copies)' do
      original = [{ type: 'vision', id: 'v1' }]
      described_class.apply_used_flags(citations: original, initial_count: 1,
                                       parse_result: { marker_found: true, used_indices: :none })
      expect(original.first).not_to have_key(:used)
    end

    it 'preserves every existing key while adding used (never reshapes the citation)' do
      flagged = described_class.apply_used_flags(
        citations: [{ type: 'ticket', id: 't1', area: 'tickets', number: 7, title: 'X' }],
        initial_count: 1, parse_result: { marker_found: true, used_indices: [1] }
      ).first
      expect(flagged).to eq(type: 'ticket', id: 't1', area: 'tickets', number: 7, title: 'X', used: true)
    end

    it 'returns a non-Array argument untouched (defensive)' do
      expect(described_class.apply_used_flags(citations: nil, initial_count: 0,
                                              parse_result: { marker_found: false, used_indices: [] })).to be_nil
    end
  end
end
