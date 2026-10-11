# frozen_string_literal: true

require 'rails_helper'

# What:  Docs::PlainText, plain text and a context snippet from rendered docs HTML.
# Type:  Unit test.
# Why:   Two searches share it (the file search and the product knowledge table). The text
#        must read as text: the sanitizer hands back "&amp;" for "&", and 35 of 84 real help
#        rows stored exactly that. The snippet has four cases that read differently: a hit in
#        the middle, at the start, near the end, and no position at all.
RSpec.describe Docs::PlainText do
  describe '.from_html' do
    it 'strips the tags and folds the whitespace' do
      expect(described_class.from_html("<h1>Titel</h1>\n<p>Ein   <b>Satz</b></p>")).to eq('Titel Ein Satz')
    end

    it 'turns nil into an empty string' do
      expect(described_class.from_html(nil)).to eq('')
    end

    it 'decodes entities, so the text reads as text' do
      expect(described_class.from_html('<p>Felder &amp; Tags &lt;neu&gt; &quot;x&quot;</p>'))
        .to eq('Felder & Tags <neu> "x"')
    end
  end

  describe '.excerpt' do
    it 'cuts around a hit in the middle, with an ellipsis on both sides' do
      text = "#{'a' * 100}NEEDLE#{'b' * 300}"

      expect(described_class.excerpt(text, text.index('NEEDLE')))
        .to start_with('… ').and end_with(' …').and include('NEEDLE')
    end

    it 'starts without an ellipsis when the hit is at the beginning' do
      expect(described_class.excerpt("NEEDLE #{'b' * 300}", 0)).to start_with('NEEDLE').and end_with(' …')
    end

    it 'ends without an ellipsis when the hit is near the end' do
      text = "#{'a' * 300}NEEDLE"

      expect(described_class.excerpt(text, text.index('NEEDLE'))).to start_with('… ').and end_with('NEEDLE')
    end

    it 'gives the beginning of a short text when there is no position' do
      expect(described_class.excerpt('kurz', nil)).to eq('kurz')
    end

    it 'cuts a long text from its start, without an ellipsis, when there is no position' do
      expect(described_class.excerpt('b' * 300, nil)).to eq('b' * described_class::SNIPPET_LENGTH)
    end
  end
end
