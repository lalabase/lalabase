# frozen_string_literal: true

require 'rails_helper'

# The one owner of the rule for the additional details of a person: kinds,
# limits, normalisation and validation.
RSpec.describe PersonDetail do
  def detail(kind: 'text', label: 'Notiz', value: 'x')
    { 'kind' => kind, 'label' => label, 'value' => value }
  end

  def problems(*entries)
    described_class.problems(entries)
  end

  describe '.normalize' do
    it 'keeps only kind, label and value, as strings' do
      raw = [{ 'kind' => 'phone', 'label' => 'Fax', 'value' => '+49 30 1234568', 'evil' => 'x', 'id' => 1 }]

      expect(described_class.normalize(raw)).to eq([detail(kind: 'phone', label: 'Fax', value: '+49 30 1234568')])
    end

    it 'takes symbol keys too' do
      expect(described_class.normalize([{ kind: 'text', label: 'A', value: 'b' }])).to eq([detail(label: 'A', value: 'b')])
    end

    it 'squeezes label and value' do
      raw = [detail(label: '  Büro   Zentrale ', value: "  +49 30\t 1234567  ")]

      expect(described_class.normalize(raw).first).to include('label' => 'Büro Zentrale', 'value' => '+49 30 1234567')
    end

    it 'drops a row without a label and a value (an empty row of the form is no detail)' do
      raw = [detail(label: '', value: '   '), detail(label: ' ', value: nil), detail(kind: 'phone', label: 'Fax', value: '1')]

      expect(described_class.normalize(raw)).to eq([detail(kind: 'phone', label: 'Fax', value: '1')])
    end

    # Review round 2, finding 1: a row whose value the browser emptied (a
    # kind switch) kept its label; dropping it lost the row behind a success.
    it 'keeps a row with a label but no value, for the validation to name it' do
      expect(described_class.normalize([detail(label: 'Geburtstag', value: '  ')])).to eq([detail(label: 'Geburtstag', value: '')])
    end

    it 'keeps an empty label as an empty string' do
      expect(described_class.normalize([detail(label: nil)]).first['label']).to eq('')
    end

    it 'keeps the lines of an address, trimmed, without empty ones' do
      raw = [detail(kind: 'address', value: "  Musterstraße 1 \r\n\r\n  12345   Berlin  \n ")]

      expect(described_class.normalize(raw).first['value']).to eq("Musterstraße 1\n12345 Berlin")
    end

    it 'joins the lines of any other kind' do
      expect(described_class.normalize([detail(value: "eins\nzwei")]).first['value']).to eq('eins zwei')
    end

    it 'keeps an unknown kind for the validation' do
      expect(described_class.normalize([detail(kind: 'fax')]).first['kind']).to eq('fax')
    end

    it 'orders an indexed hash (the form) by its index, not by the order of the keys' do
      raw = { '10' => detail(value: 'zehn'), '2' => detail(value: 'zwei'), '0' => detail(value: 'null') }

      expect(described_class.normalize(raw).pluck('value')).to eq(%w[null zwei zehn])
    end

    it 'reads ActionController::Parameters' do
      raw = ActionController::Parameters.new('0' => { 'kind' => 'url', 'label' => 'Web', 'value' => 'https://example.com' })

      expect(described_class.normalize(raw)).to eq([detail(kind: 'url', label: 'Web', value: 'https://example.com')])
    end

    it 'is empty for nothing and for the marker of an empty list' do
      expect(described_class.normalize(nil)).to eq([])
      expect(described_class.normalize('')).to eq([])
      expect(described_class.normalize({ described_class::FORM_MARKER => '1' })).to eq([])
    end

    it 'ignores junk from a hand-made request and never raises' do
      raw = {
        '0' => 'a string', '1' => %w[nested array], '2' => { 'kind' => %w[x], 'value' => { 'a' => 'b' } },
        'abc' => detail(value: 'not numeric'), '-1' => detail(value: 'negative'), '3' => detail(value: 'kept'),
        '4' => { 'kind' => 'text', 'label' => { 'x' => 'y' }, 'value' => 'label dropped' }
      }

      expect(described_class.normalize(raw)).to eq([detail(value: 'kept'), detail(label: '', value: 'label dropped')])
      expect(described_class.normalize([nil, 1, 'x', [detail]])).to eq([])
      expect(described_class.normalize(42)).to eq([])
    end

    it 'is idempotent' do
      once = described_class.normalize([detail(kind: 'address', label: ' A ', value: " x \n y ")])

      expect(described_class.normalize(once)).to eq(once)
    end
  end

  describe '.problems' do
    it 'accepts a valid detail of every kind' do
      valid = {
        'phone' => '+49 30 1234567', 'email' => 'erika@example.com', 'url' => 'https://example.com/team',
        'date' => '1980-02-29', 'address' => "Musterstraße 1\n12345 Berlin", 'text' => 'nur vormittags'
      }
      expect(valid.keys).to match_array(described_class::KINDS)

      valid.each { |kind, value| expect(problems(detail(kind: kind, value: value))).to eq([]), kind }
    end

    it 'accepts http as well as https' do
      expect(problems(detail(kind: 'url', value: 'http://example.com'))).to eq([])
      expect(problems(detail(kind: 'url', value: 'HTTPS://EXAMPLE.COM'))).to eq([])
    end

    {
      'phone' => ['keine Nummer', :invalid_phone],
      'email' => ['erika at example', :invalid_email],
      'date' => ['28.10.2026', :invalid_date],
      'url' => ['example.com', :invalid_url]
    }.each do |kind, (value, problem)|
      it "refuses an invalid #{kind}" do
        expect(problems(detail(kind: kind, value: value))).to eq([[problem, { position: 1 }]])
      end
    end

    it 'refuses an impossible date and the other ISO forms (week, ordinal, compact)' do
      %w[2026-02-30 2026-W44-3 2026-301 20261028 2026-10-28T10:00].each do |value|
        expect(problems(detail(kind: 'date', value: value))).to eq([[:invalid_date, { position: 1 }]]), value
      end
    end

    # Review round 1, finding 6: a browser accepts umlauts in a web address,
    # URI.parse does not; they must not read as "no http(s)".
    it 'accepts umlauts in the path and in the host' do
      %w[https://example.com/wiki/Köln http://ä.example.com https://example.com/straße?q=ü].each do |value|
        expect(problems(detail(kind: 'url', value: value))).to eq([]), value
        expect(described_class.new(detail(kind: 'url', value: value)).href).to eq(value)
      end
    end

    # Review round 2, finding 2: escaping the umlauts must not let invisible
    # and control characters through (bidi overrides turn the shown text).
    it 'still refuses spaces, control and format characters next to an umlaut' do
      ['https://exa mple.com/Köln', "https://example.com/Köln\u0000", "java\tscript:alert('ö')",
       "https://\u202Emoc.elpmaxe", "https://ex\u0080ample.com", "https://exa\u200Bmple.com",
       "https://exa\u00ADmple.com"].each do |value|
        expect(problems(detail(kind: 'url', value: value))).to eq([[:invalid_url, { position: 1 }]]), value.inspect
      end
    end

    it 'refuses every scheme but http and https, and a url without a host' do
      ['javascript:alert(1)', 'JavaScript:alert(1)', 'data:text/html,<b>x</b>', 'ftp://example.com',
       'mailto:erika@example.com', 'https://', '//example.com', 'https://exa mple.com',
       'http://example.com/<script>'].each do |value|
        expect(problems(detail(kind: 'url', value: value))).to eq([[:invalid_url, { position: 1 }]]), value
      end
    end

    it 'refuses an unknown kind' do
      expect(problems(detail(kind: 'fax'))).to eq([[:unknown_kind, { position: 1 }]])
      expect(problems(detail(kind: nil))).to eq([[:unknown_kind, { position: 1 }]])
    end

    it 'refuses a detail without a value' do
      expect(problems(detail(value: ''))).to eq([[:value_missing, { position: 1 }]])
      expect(described_class.problems(described_class.normalize([detail(label: 'Fax', value: '')])))
        .to eq([[:value_missing, { position: 1 }]])
    end

    it 'refuses an entry that is no hash' do
      expect(problems('x')).to eq([[:unknown_kind, { position: 1 }], [:value_missing, { position: 1 }]])
    end

    it 'checks the label length at n-1, n and n+1' do
      max = described_class::MAX_LABEL_LENGTH

      expect(problems(detail(label: 'a' * (max - 1)))).to eq([])
      expect(problems(detail(label: 'a' * max))).to eq([])
      expect(problems(detail(label: 'a' * (max + 1)))).to eq([[:label_too_long, { position: 1, count: max }]])
    end

    it 'checks the value length at n-1, n and n+1' do
      max = described_class::MAX_VALUE_LENGTH

      expect(problems(detail(value: 'a' * (max - 1)))).to eq([])
      expect(problems(detail(value: 'a' * max))).to eq([])
      expect(problems(detail(value: 'a' * (max + 1)))).to eq([[:value_too_long, { position: 1, count: max }]])
    end

    it 'gives an address more room' do
      max = described_class::MAX_ADDRESS_LENGTH
      expect(max).to be > described_class::MAX_VALUE_LENGTH

      expect(problems(detail(kind: 'address', value: 'a' * max))).to eq([])
      expect(problems(detail(kind: 'address', value: 'a' * (max + 1))))
        .to eq([[:value_too_long, { position: 1, count: max }]])
    end

    it 'names the position of the entry' do
      list = [detail, detail(kind: 'email', value: 'nope'), detail]

      expect(described_class.problems(list)).to eq([[:invalid_email, { position: 2 }]])
    end

    it 'allows ten details and refuses eleven with one problem' do
      expect(described_class.problems(Array.new(described_class::MAX) { detail })).to eq([])
      expect(described_class.problems(Array.new(described_class::MAX + 1) { detail }))
        .to eq([[:too_many, { count: described_class::MAX }]])
    end

    it 'refuses a stored value that is no list' do
      expect(described_class.problems({ 'kind' => 'text' })).to eq([[:not_a_list, {}]])
    end
  end

  describe 'a stored detail' do
    it 'links only an http(s) url, also when it was written around the validation' do
      expect(described_class.new(detail(kind: 'url', value: 'https://example.com')).href).to eq('https://example.com')
      expect(described_class.new(detail(kind: 'url', value: 'javascript:alert(1)')).href).to be_nil
    end

    it 'links a phone through its digits and an email as mailto' do
      expect(described_class.new(detail(kind: 'phone', value: '+49 (30) 123-4567')).href).to eq('tel:+49301234567')
      expect(described_class.new(detail(kind: 'email', value: 'erika@example.com')).href).to eq('mailto:erika@example.com')
    end

    it 'links neither a malformed email nor a phone without digits' do
      expect(described_class.new(detail(kind: 'email', value: 'a b')).href).to be_nil
      expect(described_class.new(detail(kind: 'phone', value: 'abc')).href).to be_nil
    end

    it 'reads a date, and nil for a malformed one' do
      expect(described_class.new(detail(kind: 'date', value: '1980-02-29')).date).to eq(Date.new(1980, 2, 29))
      expect(described_class.new(detail(kind: 'date', value: 'gestern')).date).to be_nil
    end

    it 'splits an address into its lines' do
      expect(described_class.new(detail(kind: 'address', value: "A\nB")).lines).to eq(%w[A B])
    end

    it 'reads junk without raising' do
      stored = described_class.new('x')

      expect([stored.kind, stored.label, stored.value, stored.href]).to eq([nil, '', '', nil])
    end

    it 'gives the search its value only, not its label' do
      list = [detail(label: 'Fax', value: '+49 30 1234568'), detail(kind: 'address', label: 'Büro', value: "A\nB")]

      expect(described_class.search_values(list)).to eq(['+49 30 1234568', "A\nB"])
      expect(described_class.search_values(nil)).to eq([])
    end
  end
end
