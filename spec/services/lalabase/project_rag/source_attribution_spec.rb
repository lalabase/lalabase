# frozen_string_literal: true

require 'rails_helper'

# Unit matrix for the marker parser/stripper (chat_quellen_attribution_plan.md §12).
# parse() extracts the referenced source numbers; strip() removes the marker (complete
# AND partially-streamed) so it never persists or flashes in the bubble. Both are pure
# text ops with no model/DB — the whole mechanism's correctness rests on them.
RSpec.describe Lalabase::ProjectRag::SourceAttribution do
  describe '.parse' do
    it 'reads a full marker into the used indices' do
      expect(described_class.parse('Answer.\n\n[[used_sources: 1, 3]]'))
        .to eq(marker_found: true, used_indices: [1, 3])
    end

    it 'reads `none` as the :none sentinel (explicit "used nothing")' do
      expect(described_class.parse('Answer.\n\n[[used_sources: none]]'))
        .to eq(marker_found: true, used_indices: :none)
    end

    it 'treats `NONE` case-insensitively' do
      expect(described_class.parse('x [[used_sources: NONE]]')[:used_indices]).to eq(:none)
    end

    it 'reports marker_found: false when there is no marker at all (→ fallback)' do
      expect(described_class.parse('A plain answer with no marker.'))
        .to eq(marker_found: false, used_indices: [])
    end

    it 'reports an empty index list for an empty/garbled marker (marker present, no number)' do
      # [[used_sources: ]] — the flag application treats [] like the fallback (show all),
      # NOT like :none. Distinguishing the two is why used_indices is [] here, not :none.
      expect(described_class.parse('x [[used_sources: ]]'))
        .to eq(marker_found: true, used_indices: [])
    end

    it 'takes the LAST marker when several are present' do
      expect(described_class.parse('[[used_sources: 1]] mid [[used_sources: 2, 4]]')[:used_indices])
        .to eq([2, 4])
    end

    it 'parses a marker even inside a code fence (last-wins still applies)' do
      content = "```\n[[used_sources: 5]]\n```"
      expect(described_class.parse(content)[:used_indices]).to eq([5])
    end

    it 'tolerates arbitrary whitespace inside the marker' do
      expect(described_class.parse('[[used_sources:   2 ,  7 ]]')[:used_indices]).to eq([2, 7])
    end

    it 'tolerates whitespace around opener and colon ([[ used_sources : … ]])' do
      expect(described_class.parse('A [[ used_sources : 1, 3 ]]'))
        .to eq(marker_found: true, used_indices: [1, 3])
    end

    it 'drops a non-positive number (0 is not a 1-based source)' do
      expect(described_class.parse('[[used_sources: 0, 2]]')[:used_indices]).to eq([2])
    end

    it 'does NOT recognise a marker carrying letters (regex only allows digits/commas/space)' do
      # A malformed `[[used_sources: 1, foo]]` fails the character class → no marker →
      # fallback (show all), exactly the safe degradation the plan wants.
      expect(described_class.parse('[[used_sources: 1, foo]]')).to eq(marker_found: false, used_indices: [])
    end

    it 'returns the no-marker shape for blank/nil input' do
      expect(described_class.parse(nil)).to eq(marker_found: false, used_indices: [])
      expect(described_class.parse('')).to eq(marker_found: false, used_indices: [])
    end
  end

  describe '.strip' do
    it 'removes a trailing complete marker and the whitespace before it' do
      expect(described_class.strip("Here is the answer.\n\n[[used_sources: 1, 3]]"))
        .to eq('Here is the answer.')
    end

    it 'removes a `none` marker' do
      expect(described_class.strip("Answer.\n[[used_sources: none]]")).to eq('Answer.')
    end

    it 'removes ALL markers, not just the last (marker mid-text is stripped too)' do
      expect(described_class.strip('a [[used_sources: 1]] b [[used_sources: 2]]')).to eq('a  b')
    end

    it 'returns the input UNCHANGED (same object) when there is no marker — inert on normal answers' do
      text = "A normal answer.\n\nWith paragraphs."
      expect(described_class.strip(text)).to be(text)
    end

    it 'strips a partially-streamed marker at the end: only the opener has arrived' do
      expect(described_class.strip('Streaming answer [[used_sources:')).to eq('Streaming answer')
    end

    it 'strips a partial marker whose content is incomplete (no closer yet)' do
      expect(described_class.strip('Answer [[used_sources: 1,')).to eq('Answer')
    end

    it 'strips a partial marker with one closing bracket (second `]` not yet arrived)' do
      expect(described_class.strip('Answer [[used_sources: 1,3]')).to eq('Answer')
    end

    it 'strips a partial that is only a prefix of the opener (`[[u`)' do
      expect(described_class.strip('Answer [[u')).to eq('Answer')
    end

    it 'leaves a lone closing bracket alone (not a marker prefix)' do
      text = 'See item [1]'
      expect(described_class.strip(text)).to be(text)
    end

    # P2 review find: strip is DECOUPLED from parse strictness — any payload the
    # model puts inside the marker is removed, even when parse rejects it (parse
    # then falls back to "show all"; the reader must never see the marker).
    it 'strips a full marker whose payload parse would reject' do
      [
        'X [[used_sources: 1 and 3]]',
        'X [[used_sources: 1, 3 (die Tickets)]]',
        'X [[used_sources: all]]',
        'X [[used_sources: Ticket 1, Ticket 3]]',
        'X [[used_sources: #1, #3]]',
        'X [[used_sources: 1; 3]]',
        'X [[ used_sources: 1 ]]'
      ].each do |content|
        expect(described_class.strip(content)).to eq('X'), "expected the marker stripped in #{content.inspect}"
      end
    end

    it 'keeps a legitimate answer ending in a single `[` intact (no nibbling; review find)' do
      text = 'array access foo['
      expect(described_class.strip(text)).to be(text)
    end

    it 'still strips a trailing `[[` (the minimal partial-marker prefix)' do
      expect(described_class.strip('Answer [[')).to eq('Answer')
    end

    it 'returns an empty string for content that is nothing but a marker' do
      expect(described_class.strip('[[used_sources: 1]]')).to eq('')
    end

    it 'handles nil' do
      expect(described_class.strip(nil)).to eq('')
    end
  end
end
