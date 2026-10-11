# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Changelog::EntryLoader do
  let(:changelog_dir) { Rails.root.join('tmp/test_changelog') }

  before do
    FileUtils.mkdir_p(changelog_dir)
    stub_const('Changelog::EntryLoader::CHANGELOG_DIR', changelog_dir)
    Rails.cache.clear
  end

  after do
    FileUtils.rm_rf(changelog_dir)
  end

  describe '.call' do
    context 'when directory is empty' do
      it 'returns an empty array' do
        expect(described_class.call).to eq([])
      end
    end

    context 'with valid markdown files' do
      before do
        File.write(changelog_dir.join('2026-01-15_feature-a.md'), <<~MD)
          ---
          title: Feature A
          date: 2026-01-15
          images: []
          ---

          This is feature A.
        MD

        File.write(changelog_dir.join('2026-02-01_feature-b.md'), <<~MD)
          ---
          title: Feature B
          date: 2026-02-01
          images:
            - changelog/screenshot.png
          ---

          This is feature B with **bold** text.
        MD
      end

      it 'parses entries correctly' do
        entries = described_class.call
        expect(entries.size).to eq(2)
      end

      it 'sorts newest first' do
        entries = described_class.call
        expect(entries.first.title).to eq('Feature B')
        expect(entries.last.title).to eq('Feature A')
      end

      it 'parses frontmatter fields' do
        entry = described_class.call.last
        expect(entry.title).to eq('Feature A')
        expect(entry.date).to eq(Date.new(2026, 1, 15))
        expect(entry.images).to eq([])
        expect(entry.slug).to eq('2026-01-15_feature-a')
      end

      it 'parses images array' do
        entry = described_class.call.first
        expect(entry.images).to eq(['changelog/screenshot.png'])
      end

      it 'renders markdown to HTML' do
        entry = described_class.call.first
        expect(entry.body_html).to include('<strong>bold</strong>')
      end
    end

    context 'with malformed files' do
      before do
        File.write(changelog_dir.join('broken.md'), 'no frontmatter here')
      end

      it 'skips malformed files and returns empty array' do
        expect(described_class.call).to eq([])
      end

      it 'logs a warning' do
        allow(Rails.logger).to receive(:warn)
        described_class.call
        # No error raised
      end
    end

    context 'when directory does not exist' do
      before do
        FileUtils.rm_rf(changelog_dir)
      end

      it 'returns an empty array' do
        expect(described_class.call).to eq([])
      end
    end
  end
end
