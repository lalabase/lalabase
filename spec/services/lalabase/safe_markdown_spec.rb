# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::SafeMarkdown — the shared two-layer safe-Markdown renderer.
# Type: Service spec.
# Why:  This is the SINGLE security contract behind both the chat bubbles and the
#       meeting detail. It must (1) render Markdown syntax to real HTML and (2)
#       sanitise the result against a strict allowlist — no raw HTML, no <script>,
#       no event handlers, no <img> (tracking-pixel / exfil vector). If anyone
#       weakens either layer, these fire.
RSpec.describe Lalabase::SafeMarkdown do
  def render_md(text) = described_class.render(text)

  describe 'Markdown rendering (syntax becomes HTML, not literal characters)' do
    it 'renders emphasis, inline code and fenced code blocks' do
      html = render_md("**bold** _i_ `c`\n\n```\np\n```")
      expect(html).to include('<strong>bold</strong>')
      expect(html).to include('<em>i</em>')
      expect(html).to include('<code>c</code>')
      expect(html).to include('<pre>')
    end

    it 'renders headings as <h*>, not literal ## text' do
      html = render_md("## Überschrift\n\nbody")
      expect(html).to include('<h2>Überschrift</h2>')
      expect(html).not_to include('## Überschrift')
    end

    it 'renders a "**Sprecher:**" label as bold (the meeting transcript shape)' do
      expect(render_md('**Guido:** Wir starten.')).to include('<strong>Guido:</strong>')
    end

    it 'renders lists as <ul><li>' do
      html = render_md("- one\n- two")
      expect(html).to include('<ul>')
      expect(html).to include('<li>one</li>')
    end

    it 'renders a "---" line as a horizontal rule' do
      expect(render_md("above\n\n---\n\nbelow")).to include('<hr>')
    end

    it 'returns an html_safe String so callers render it raw' do
      expect(render_md('**x**')).to be_html_safe
    end
  end

  describe 'XSS protection (the second sanitize layer)' do
    it 'strips <script> from the source (executable path closed)' do
      html = render_md("<script>alert('xss')</script>Hello")
      expect(html).not_to include('<script>')
      expect(html).not_to include('</script>')
      expect(html).to include('Hello')
    end

    it 'does not carry an onclick handler through (raw HTML stripped at render)' do
      html = render_md('<span onclick="evil()" title="ok">text</span>')
      expect(html).not_to include('onclick')
      expect(html).to include('<p>text</p>') # span stripped, plain text remains
    end

    it 'renders a safe link but drops a javascript: link (no executable href)' do
      html = render_md('[good](https://ok.com) [bad](javascript:alert)')
      expect(html).to include('href="https://ok.com"')
      expect(html).not_to include('javascript:')
    end

    it 'renders NO <img> for Markdown image syntax (tracking-pixel vector closed)' do
      html = render_md('![img](https://tracker/pixel.png)')
      expect(html).not_to include('<img')
    end

    it 'strips a raw <img> tag from the source too' do
      html = render_md('<p>safe</p><img src="https://tracker/pixel.png">')
      expect(html).not_to include('<img')
      expect(html).to include('safe')
    end

    it 'strips <iframe> / <table> (not part of the safe surface)' do
      expect(render_md('<iframe src="evil"></iframe>safe')).not_to include('<iframe')
      expect(render_md('<table><tr><td>x</td></tr></table>')).not_to include('<table')
    end
  end

  describe 'blank handling' do
    it 'returns a blank html_safe String for nil' do
      expect(render_md(nil)).to eq('')
      expect(render_md(nil)).to be_html_safe
    end

    it 'returns a blank html_safe String for an empty string' do
      expect(render_md('')).to eq('')
    end
  end

  # The one-line reading a timeline line uses: a changed summary that stays in
  # the line must not show "**Modifikation**" (Aktivitätenfeed, 10.09.2026).
  describe '.plain_text (the same Markdown, read as one line)' do
    def plain(text) = described_class.plain_text(text)

    it 'drops the marks and keeps the words' do
      expect(plain('Die **Modifikation** ist _fertig_, ~~alt~~ und `neu`'))
        .to eq('Die Modifikation ist fertig, alt und neu')
    end

    it 'reads snake_case as a word, like .render (no intra-word emphasis)' do
      expect(plain('user_id und snake_case_name')).to eq('user_id und snake_case_name')
    end

    it 'folds paragraphs and line breaks into one line' do
      expect(plain("Absatz eins.\n\nAbsatz zwei\nmit Umbruch.")).to eq('Absatz eins. Absatz zwei mit Umbruch.')
    end

    it 'returns an unsafe String, so the caller escapes it like any text' do
      expect(plain('<script>alert(1)</script> **x**')).not_to be_html_safe
    end

    it 'returns a blank String for nil' do
      expect(plain(nil)).to eq('')
    end
  end

  describe 'allowlist locked as contract' do
    it { expect(described_class::ALLOWED_TAGS).to be_frozen }
    it { expect(described_class::ALLOWED_ATTRIBUTES).to be_frozen }
    it { expect(described_class::ALLOWED_TAGS).to include('p', 'strong', 'em', 'code', 'a', 'h2', 'hr') }
    it { expect(described_class::ALLOWED_TAGS).not_to include('img', 'table', 'svg', 'script', 'iframe', 'style') }
    it { expect(described_class::ALLOWED_ATTRIBUTES).to include('href') }
    it { expect(described_class::ALLOWED_ATTRIBUTES).not_to include('onclick', 'onload', 'onerror', 'style', 'src') }
  end
end
