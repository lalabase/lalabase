# frozen_string_literal: true

require 'rails_helper'

# What:  Wiki::ReferenceExtractor — canonical HTML → unique target records (D3).
# Type:  Unit spec, no DB (resolution via an injected fake resolver).
# Why:   The link index is built from the source of truth (sgid attachments), not the
#        derived markdown. We test that it resolves mentions, skips unresolvable ones,
#        de-dups, and ignores non-mention attachments.
RSpec.describe Wiki::ReferenceExtractor do
  let(:note_a) { double('Note A') }
  let(:doc_b)  { double('Document B') }

  # Mirrors MentionResolver#record_for (sgid → record) without touching the DB.
  let(:resolver) do
    instance_double(Wiki::MentionResolver).tap do |r|
      allow(r).to receive(:record_for) do |sgid|
        { 'sgid-a' => note_a, 'sgid-b' => doc_b }[sgid]
      end
    end
  end
  subject(:extractor) { described_class.new(resolver: resolver) }

  def mention(sgid)
    <<~HTML.strip
      <action-text-attachment sgid="#{sgid}"
        content-type="application/vnd.actiontext.mention"></action-text-attachment>
    HTML
  end

  it 'returns the resolved target records for the mentions' do
    html = "<p>#{mention('sgid-a')} and #{mention('sgid-b')}</p>"
    expect(extractor.call(html)).to contain_exactly(note_a, doc_b)
  end

  it 'skips unresolvable mentions (deleted/forged sgid)' do
    html = "<p>#{mention('sgid-a')} #{mention('sgid-gone')}</p>"
    expect(extractor.call(html)).to contain_exactly(note_a)
  end

  it 'de-dups a target mentioned more than once' do
    html = "<p>#{mention('sgid-a')} #{mention('sgid-a')}</p>"
    expect(extractor.call(html)).to contain_exactly(note_a)
  end

  it 'ignores non-mention attachments' do
    html = %(<action-text-attachment sgid="sgid-a" content-type="image/png"></action-text-attachment>)
    expect(extractor.call(html)).to eq([])
  end

  it 'returns an empty array for blank input' do
    expect(extractor.call(nil)).to eq([])
    expect(extractor.call('')).to eq([])
  end
end
