# frozen_string_literal: true

require 'rails_helper'

# What:  Wiki::VersionDiff — line diff of two NoteVersions over markdown_body, for the
#        unified history view.
# Type:  Unit spec (no DB — versions are doubles carrying only markdown_body).
# Why:   This is the logic the diff view hangs on. We pin each sdiff action mapping
#        (unchanged / added / removed / replaced) and the v0 (nil predecessor) case.
RSpec.describe Wiki::VersionDiff do
  def version(markdown)
    instance_double(NoteVersion, markdown_body: markdown)
  end

  def pairs(diff)
    diff.map { |line| [line.type, line.text] }
  end

  it 'keeps unchanged lines' do
    expect(pairs(described_class.call(version("a\nb"), version("a\nb"))))
      .to eq([[:unchanged, 'a'], [:unchanged, 'b']])
  end

  it 'marks an added line' do
    expect(pairs(described_class.call(version('a'), version("a\nb"))))
      .to eq([[:unchanged, 'a'], [:added, 'b']])
  end

  it 'marks a removed line' do
    expect(pairs(described_class.call(version("a\nb"), version('a'))))
      .to eq([[:unchanged, 'a'], [:removed, 'b']])
  end

  # A replaced line ('!' in sdiff) must surface BOTH sides, removed then added — not a
  # single rewritten line (which would hide what changed).
  it 'renders a replaced line as removed-then-added' do
    expect(pairs(described_class.call(version('old'), version('new'))))
      .to eq([[:removed, 'old'], [:added, 'new']])
  end

  # The v0 baseline has no predecessor → the whole content reads as added.
  it 'treats a nil predecessor as everything added' do
    expect(pairs(described_class.call(nil, version("a\nb"))))
      .to eq([[:added, 'a'], [:added, 'b']])
  end

  it 'returns no lines when both versions are blank' do
    expect(described_class.call(version(nil), version(''))).to eq([])
  end
end
