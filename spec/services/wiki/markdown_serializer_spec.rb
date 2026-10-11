# frozen_string_literal: true

require 'rails_helper'

# What:  Wiki::MarkdownSerializer — HTML(ActionText) <-> GFM Markdown.
# Type:  Unit spec, no DB (mention resolution via an injected fake resolver).
# Why:   The serializer is the ONE path the spike decisions hang on. If it breaks,
#        markdown_body, diffs, import and (later) MCP all break at once. So we test
#        not "it runs through" but the hard contracts at the breaking points the
#        spike found empirically.
# Contracts:
#   - GFM-simple tables survive HTML→MD→HTML content-faithfully.
#   - Block content in cells is REJECTED (not silently swallowed).
#   - Pipes in cell content do NOT break the table (they are escaped).
#   - Mentions become [Title](lalabase:type/uuid) with type+uuid, never the sgid.
#   - The lalabase: link survives the way back (comrak does not strip the scheme).
RSpec.describe Wiki::MarkdownSerializer do
  # Mirrors what resolves the signed GlobalID in real operation — here without a DB.
  let(:resolver) do
    lambda do |sgid|
      { 'sgid-target' => { type: 'note', id: 'uuid-9', title: 'Target note' } }[sgid]
    end
  end
  subject(:serializer) { described_class.new(mention_resolver: resolver) }

  # Compares two HTML tables by content (cell text), not byte-for-byte — the spike
  # confirmed whitespace is not stable, but the content is.
  def cell_texts(html)
    Nokogiri::HTML.fragment(html).css('td, th').map { |c| c.text.strip }
  end

  describe '#to_markdown — tables' do
    # Intent: a GFM-simple table becomes valid pipe Markdown including the separator row.
    it 'turns a simple table into valid GFM with a header separator' do
      html = <<~HTML
        <table><tbody>
          <tr><th>Task</th><th>Status</th></tr>
          <tr><td>Login</td><td>open</td></tr>
        </tbody></table>
      HTML

      md = serializer.to_markdown(html)

      expect(md).to include('| Task | Status |')
      expect(md).to match(/\|\s*---\s*\|\s*---\s*\|/)
      expect(md).to include('| Login | open |')
    end

    # Intent: the full round trip preserves all cell content (the serializer's core contract).
    it 'preserves all cell content on the HTML→MD→HTML round trip' do
      html = <<~HTML
        <table><tbody>
          <tr><th>Task</th><th>Status</th><th>Effort</th></tr>
          <tr><td>Login</td><td>open</td><td>3h</td></tr>
          <tr><td>Export</td><td>done</td><td>5h</td></tr>
        </tbody></table>
      HTML

      round_tripped = serializer.to_html(serializer.to_markdown(html))

      expect(cell_texts(round_tripped)).to eq(cell_texts(html))
    end

    # Intent: Lexxy wraps tables in <figure> — that must not break detection.
    it 'detects a table wrapped in a Lexxy <figure> wrapper' do
      html = <<~HTML
        <figure class="lexxy-content__table-wrapper"><table><tbody>
          <tr><th>K</th></tr><tr><td>1</td></tr>
        </tbody></table></figure>
      HTML

      md = serializer.to_markdown(html)

      expect(md).to include('| K |')
      expect(md).to include('| 1 |')
    end

    # Intent: round-trip the EXACT HTML Lexxy emits (captured live, not invented): a
    # <figure> wrapper, a tbody-only table whose header row uses <th>, and — crucially —
    # every cell's content wrapped in a <p>. The <p> wrappers are what shattered the table
    # before unwrap_cell_paragraphs! existed, so this is the regression guard for that fix.
    it 'round-trips the exact HTML Lexxy emits (figure wrapper + <p>-wrapped cells)' do
      html = <<~HTML
        <figure class="lexxy-content__table-wrapper"><table><tbody>
          <tr><th class="lexxy-content__table-cell--header"><p>Task</p></th>
              <th class="lexxy-content__table-cell--header"><p>Status</p></th></tr>
          <tr><td><p>Login</p></td><td><p>open</p></td></tr>
          <tr><td><p>Export</p></td><td><p>done</p></td></tr>
        </tbody></table></figure>
      HTML

      md = serializer.to_markdown(html)
      expect(md).to include('| Task | Status |')
      expect(md).to match(/\|\s*---\s*\|\s*---\s*\|/)
      expect(md).to include('| Login | open |')

      round_tripped = serializer.to_html(md)
      expect(cell_texts(round_tripped)).to eq(%w[Task Status Login open Export done])
    end
  end

  describe '#to_markdown — block-in-cell guard (spike finding)' do
    # Intent: Lexxy ALLOWS block content in cells, but it breaks the round trip.
    # The serializer must reject it hard, not silently flatten it.
    it 'rejects a list in a cell with BlockContentInTableCellError' do
      html = '<table><tbody><tr><th>K</th></tr>' \
             '<tr><td><ul><li>a</li><li>b</li></ul></td></tr></tbody></table>'

      expect { serializer.to_markdown(html) }
        .to raise_error(described_class::BlockContentInTableCellError)
    end

    # Intent: inline markup (bold/link) in cells is allowed and NOT rejected.
    it 'allows inline markup in cells' do
      html = '<table><tbody><tr><th>K</th></tr>' \
             '<tr><td>a <strong>bold</strong> value</td></tr></tbody></table>'

      expect { serializer.to_markdown(html) }.not_to raise_error
    end

    # Intent: a cell whose content is a SINGLE <p> is Lexxy's normal structure — it is
    # unwrapped, not rejected. (Mutation guard for unwrap_cell_paragraphs!.)
    it 'allows a single <p>-wrapped cell (Lexxy structure)' do
      html = '<table><tbody><tr><th><p>K</p></th></tr>' \
             '<tr><td><p>a <strong>bold</strong> value</p></td></tr></tbody></table>'

      expect { serializer.to_markdown(html) }.not_to raise_error
    end

    # Intent: more than one paragraph in a cell is genuine block content (a paragraph
    # break has no GFM-cell representation) → reject instead of silently flattening it.
    it 'rejects a cell with multiple paragraphs' do
      html = '<table><tbody><tr><th><p>K</p></th></tr>' \
             '<tr><td><p>line one</p><p>line two</p></td></tr></tbody></table>'

      expect { serializer.to_markdown(html) }
        .to raise_error(described_class::BlockContentInTableCellError)
    end

    # Mutation guard: text alongside a <p> must NOT be silently dropped by the unwrap.
    # Unwrapping only the <p> would lose "Lead"; the cell is rejected as block content instead.
    it 'rejects (does not silently drop) text mixed with a paragraph in a cell' do
      html = '<table><tbody><tr><th><p>K</p></th></tr>' \
             '<tr><td>Lead<p>tail</p></td></tr></tbody></table>'

      expect { serializer.to_markdown(html) }
        .to raise_error(described_class::BlockContentInTableCellError)
    end

    # Mutation guard: shrinking CELL_BREAKING_TAGS (e.g. dropping 'ol') would silently
    # let that tag through and break the round trip. Iterate the constant so each tag
    # is positively covered — removing any one turns its example red.
    described_class::CELL_BREAKING_TAGS.each do |tag|
      it "rejects <#{tag}> block content in a cell" do
        html = "<table><tbody><tr><th>K</th></tr><tr><td><#{tag}></#{tag}></td></tr></tbody></table>"

        expect { serializer.to_markdown(html) }
          .to raise_error(described_class::BlockContentInTableCellError)
      end
    end
  end

  describe '#to_markdown — pipe escaping (spike finding)' do
    # Intent: a "|" in cell content must not break the column structure.
    it 'escapes pipes in cell content and keeps the column count on the round trip' do
      html = '<table><tbody><tr><th>A</th><th>B</th></tr>' \
             '<tr><td>x|y</td><td>z</td></tr></tbody></table>'

      md = serializer.to_markdown(html)
      expect(md).to include('x\|y')

      round_tripped = serializer.to_html(md)
      expect(cell_texts(round_tripped)).to eq(%w[A B x|y z])
    end
  end

  describe '#to_markdown — mentions' do
    # Intent: a mention attachment becomes a lalabase: placeholder with type+uuid.
    it 'turns a mention attachment into [Title](lalabase:type/uuid)' do
      html = <<~HTML
        <p>See <action-text-attachment sgid="sgid-target"
          content-type="application/vnd.actiontext.mention"
          content="Target note"></action-text-attachment>.</p>
      HTML

      md = serializer.to_markdown(html)

      expect(md).to include('[Target note](lalabase:note/uuid-9)')
    end

    # Intent: never carries the signed sgid into the placeholder (security contract).
    it 'does not leak the sgid into the Markdown placeholder' do
      html = <<~HTML
        <action-text-attachment sgid="sgid-target"
          content-type="application/vnd.actiontext.mention"
          content="Target note"></action-text-attachment>
      HTML

      expect(serializer.to_markdown(html)).not_to include('sgid-target')
    end

    # Intent: an unresolvable target (deleted) becomes plain text, not a dead link.
    it 'falls back to plain text for an unresolvable target' do
      html = <<~HTML
        <action-text-attachment sgid="sgid-gone"
          content-type="application/vnd.actiontext.mention"
          content="Vanished"></action-text-attachment>
      HTML

      md = serializer.to_markdown(html)

      expect(md).to include('Vanished')
      expect(md).not_to include('lalabase:')
    end
  end

  describe '#to_html — internal scheme' do
    # Intent: comrak must not strip the lalabase: link as unsafe.
    it 'keeps the lalabase: link intact on the way back' do
      md = 'See [Note](lalabase:note/uuid-9).'

      html = serializer.to_html(md)

      expect(html).to include('href="lalabase:note/uuid-9"')
    end
  end

  describe '#to_html — XSS safety (no unsafe rendering)' do
    # Mutation guard: re-introducing render unsafe:true would pass raw HTML through and keep
    # javascript: hrefs — a stored-XSS sink for the future MCP write path. The lalabase: test
    # above proves the internal scheme still survives WITHOUT unsafe.
    it 'omits raw HTML and neutralizes dangerous link schemes' do
      html = serializer.to_html("Hi\n\n<script>alert(1)</script>\n\n[x](javascript:alert(1))")

      expect(html).not_to include('<script')
      expect(html).not_to include('javascript:')
    end
  end

  describe 'edge cases' do
    it 'returns an empty string for blank input' do
      expect(serializer.to_markdown(nil)).to eq('')
      expect(serializer.to_markdown('')).to eq('')
      expect(serializer.to_html(nil)).to eq('')
    end
  end
end
