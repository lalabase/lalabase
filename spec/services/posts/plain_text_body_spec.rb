# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Posts::PlainTextBody do
  cases = {
    'single line breaks' => ["line one\nline two", '<p>line one<br>line two</p>'],
    'operators' => ['a < b && c > d', '<p>a &lt; b &amp;&amp; c &gt; d</p>'],
    'literal markup' => ['<b>bold</b> <script>alert(1)</script>',
                         '<p>&lt;b&gt;bold&lt;/b&gt; &lt;script&gt;alert(1)&lt;/script&gt;</p>'],
    'typed entities' => ['literal &lt;tag&gt;', '<p>literal &amp;lt;tag&amp;gt;</p>'],
    'indented code' => ["if ready\n  puts \"<hi>\"\nend", '<p>if ready<br>  puts &quot;&lt;hi&gt;&quot;<br>end</p>'],
    'file names' => ['see <file.txt>', '<p>see &lt;file.txt&gt;</p>'],
    'paragraphs' => ["a\nb\n\nc", '<p>a<br>b</p><p>c</p>'],
    'repeated and outer blank lines' => ["\n\na\n\n\n\nc\n\n", '<p>a</p><p>c</p>'],
    'whitespace-only blank lines' => ["a\n \t\nb", '<p>a</p><p>b</p>'],
    'CRLF' => ["a\r\nb\r\n\r\nc", '<p>a<br>b</p><p>c</p>'],
    'lone CR' => ["a\rb\r\rc", '<p>a<br>b</p><p>c</p>'],
    'outer line breaks' => ["\nHallo\n", '<p>Hallo</p>'],
    'outer CRLF with indentation' => ["\r\n  Hallo  \r\n", '<p>  Hallo  </p>'],
    'whitespace-only lines at the edges' => [" \nfoo\n   ", '<p>foo</p>'],
    'only Unicode whitespace' => [0xA0.chr(Encoding::UTF_8), ''],
    'spaces and tabs' => ["a  b\n\t  c", "<p>a  b<br>\t  c</p>"],
    'empty text' => ['', ''],
    'blank text' => ["\n \t\n\n", ''],
    'HTML-safe strings as literal text' => ['<b>literal</b>'.html_safe, '<p>&lt;b&gt;literal&lt;/b&gt;</p>']
  }

  cases.each do |label, (body, html)|
    it "converts #{label}" do
      original = body.dup
      expect(described_class.call(body: body)).to eq(html)
      expect(body).to eq(original)
    end
  end
end
