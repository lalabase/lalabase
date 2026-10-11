# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Indexer::Symbols::SignatureExtraction do
  # The module is a mixin with one contract: the includer sets @source_lines.
  # Both real extractors share it, so we pin its boundaries ONCE here — directly,
  # at the unit level — instead of duplicating line-window / length-cap tests in
  # every extractor spec. The extractor specs then only verify the WIRING
  # (node line number → extract_signature).
  let(:host_class) do
    Class.new do
      include Lalabase::Indexer::Symbols::SignatureExtraction

      def initialize(lines)
        @source_lines = lines
      end

      # Expose the private method under test.
      def signature(start_line)
        extract_signature(start_line)
      end
    end
  end

  def sig(lines, start_line)
    host_class.new(lines).signature(start_line)
  end

  describe 'line window — first SIGNATURE_LINE_LIMIT lines from start_line' do
    let(:lines) { "line1\nline2\nline3\nline4\nline5\n".lines }

    it 'takes exactly SIGNATURE_LINE_LIMIT lines starting at start_line' do
      expect(sig(lines, 2)).to eq("line2\nline3\nline4") # lines 2,3,4 — the 3-line window
    end

    it 'starts at the very first line for start_line 1' do
      expect(sig(lines, 1)).to eq("line1\nline2\nline3")
    end

    it 'returns just the last line when start_line is the last line (upper clamp)' do
      expect(sig(lines, 5)).to eq('line5')
    end
  end

  describe 'length cap — n-1 / n / n+1 around MAX_SIGNATURE_LENGTH' do
    def line_of(length)
      ["#{'x' * length}\n"]
    end

    it 'leaves a signature one char under the cap untouched' do
      expect(sig(line_of(described_class::MAX_SIGNATURE_LENGTH - 1), 1).length)
        .to eq(described_class::MAX_SIGNATURE_LENGTH - 1)
    end

    it 'leaves a signature exactly at the cap untouched' do
      expect(sig(line_of(described_class::MAX_SIGNATURE_LENGTH), 1).length)
        .to eq(described_class::MAX_SIGNATURE_LENGTH)
    end

    it 'truncates a signature one char over the cap' do
      expect(sig(line_of(described_class::MAX_SIGNATURE_LENGTH + 1), 1).length)
        .to eq(described_class::MAX_SIGNATURE_LENGTH)
    end
  end

  describe 'defensive clamps — inputs the extractors never produce, but the unit must survive' do
    it 'clamps start_line 0 to the first line (the [.., 0].max guard)' do
      # Without the max-0 clamp, start_line 0 → first index -1 → Ruby wraps to the
      # LAST line ("b"). The clamp keeps the window anchored at the first line.
      expect(sig(%W[a\n b\n], 0)).to eq("a\nb")
    end

    it 'returns "" when start_line is past the end of the source' do
      expect(sig(%W[a\n b\n], 99)).to eq('')
    end

    it 'returns "" for empty source' do
      expect(sig([], 1)).to eq('')
    end
  end

  describe 'whitespace' do
    it 'strips surrounding blank lines and indentation' do
      expect(sig(["   \n", "  hello  \n", "\n"], 1)).to eq('hello')
    end
  end

  describe 'constants locked as contract (this module is their canonical home)' do
    it { expect(described_class::SIGNATURE_LINE_LIMIT).to eq(3) }
    it { expect(described_class::MAX_SIGNATURE_LENGTH).to eq(500) }
  end
end
