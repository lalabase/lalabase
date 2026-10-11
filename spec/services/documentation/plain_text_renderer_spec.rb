# frozen_string_literal: true

require 'rails_helper'

# What: Documentation::PlainTextRenderer — markdown → plain text for embeddings.
# Type: Service spec.
# Why:  The embedding vector must carry meaning, not markdown syntax. This pins
#       that headings/emphasis/links/fences degrade to readable text (StripDown),
#       and that blank input yields '' so the embedding service skips the page.
RSpec.describe Documentation::PlainTextRenderer do
  subject(:render) { described_class.new.render(markdown) }

  describe 'strips markdown syntax' do
    let(:markdown) { "# Deploy Guide\n\nRun **cap** and `bin/setup`, see [runbook](https://x/run)." }

    it 'drops heading, emphasis and inline-code markers but keeps the words' do
      expect(render).to include('Deploy Guide', 'Run', 'cap', 'bin/setup', 'runbook')
      expect(render).not_to include('#', '**', '`')
    end

    it 'does not keep the markdown link brackets' do
      expect(render).not_to include('[runbook]')
    end
  end

  describe 'list + fenced code' do
    let(:markdown) { "- one\n- two\n\n```ruby\nputs 42\n```" }

    it 'keeps list item and code text as plain words' do
      expect(render).to include('one', 'two', 'puts 42')
    end
  end

  # A caller projecting stored values rather than pages meets identifiers as
  # often as prose. By default Redcarpet reads "waiting_for_customer" as
  # emphasis and "#123" as a heading; these two extensions keep both whole.
  describe 'with the extensions for stored values' do
    subject(:render) { described_class.new(no_intra_emphasis: true, space_after_headers: true).render(markdown) }

    let(:markdown) { "**Modifikation** für waiting_for_customer\n\n#123 bleibt" }

    it 'keeps identifiers whole and still takes the markup out' do
      expect(render).to include('Modifikation für waiting_for_customer', '#123 bleibt')
      expect(render).not_to include('**')
    end
  end

  describe 'blank input' do
    it 'returns an empty string for nil (service then skips the page)' do
      expect(described_class.new.render(nil)).to eq('')
    end

    it 'returns an empty string for an empty string' do
      expect(described_class.new.render('')).to eq('')
    end

    it 'returns an empty string for whitespace-only input' do
      expect(described_class.new.render("   \n\t")).to eq('')
    end
  end
end
