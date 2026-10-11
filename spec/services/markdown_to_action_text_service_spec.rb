# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MarkdownToActionTextService do
  describe '.convert' do
    it 'converts markdown to ActionText' do
      markdown = "# Hello\n\nThis is **bold** text."
      result = described_class.convert(markdown)

      expect(result).to be_a(ActionText::Content)
      expect(result.to_html).to include('<h1>Hello</h1>')
      expect(result.to_html).to include('<strong>bold</strong>')
    end

    it 'handles empty content' do
      result = described_class.convert('')
      expect(result).to be_nil
    end

    it 'handles nil content' do
      result = described_class.convert(nil)
      expect(result).to be_nil
    end

    it 'converts links with target blank' do
      markdown = '[Google](https://google.com)'
      result = described_class.convert(markdown)

      expect(result.to_html).to include('target="_blank"')
      expect(result.to_html).to include('rel="noopener"')
    end

    it 'converts code blocks' do
      markdown = "```ruby\ncode here\n```"
      result = described_class.convert(markdown)

      expect(result.to_html).to include('<pre>')
      expect(result.to_html).to include('code here')
    end

    it 'converts tables' do
      markdown = "| Col 1 | Col 2 |\n|-------|-------|\n| Val 1 | Val 2 |"
      result = described_class.convert(markdown)

      expect(result.to_html).to include('<table>')
      expect(result.to_html).to include('<th>')
      expect(result.to_html).to include('<td>')
    end
  end
end
