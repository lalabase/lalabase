# frozen_string_literal: true

require 'rails_helper'

# Pure logic, NO DB access (that is the point of the PORO) -> no rails_helper setup needed,
# but we load it anyway so that the constant is autoloaded.
RSpec.describe OrgColor do
  describe 'PALETTE / HEXES' do
    it 'HEXES sind die Palette-Hexe in Reihenfolge und alle gueltig' do
      expect(described_class::HEXES).to eq(described_class::PALETTE.map { |c| c[:hex] })
      expect(described_class::HEXES).to all(match(/\A#\h{6}\z/))
    end

    it 'PALETTE und HEXES sind eingefroren (keine versehentliche Mutation)' do
      expect(described_class::PALETTE).to be_frozen
      expect(described_class::HEXES).to be_frozen
    end

    it 'PALETTE ist der eingefrorene Daten-Vertrag (historische Sidebar-Farben)' do
      # Hardcoded expected list, DELIBERATELY NOT derived from the constant
      # (lesson from the user split: if someone shrinks the constant, the example
      # would otherwise disappear instead of going red). The hexes are the historical
      # sidebar colors — choices already stored in users.preferences must remain
      # valid palette values (see comment in org_color.rb).
      # A DELIBERATE EXTENSION of the palette is fine -> then adjust the pin deliberately.
      expect(described_class::PALETTE.map { |c| c[:key] })
        .to eq(%w[sand mint sky lavender rose peach cyan lime])
      expect(described_class::HEXES)
        .to eq(%w[#fef3c7 #d1fae5 #dbeafe #ede9fe #ffe4e6 #ffedd5 #cffafe #ecfccb])
    end
  end

  describe '.hex?' do
    it 'akzeptiert nur #rrggbb' do
      expect(described_class.hex?('#fef3c7')).to be(true)
    end

    it 'lehnt OFF, nil, Kurz-Hex, Hex ohne # und Unsinn ab' do
      [described_class::OFF, nil, '', '#fff', 'fef3c7', '#GGGGGG', :sym].each do |bad|
        expect(described_class.hex?(bad)).to be(false), "erwartet hex?(#{bad.inspect}) == false"
      end
    end

    it 'verlangt exakt #rrggbb — kein eingebetteter, zu langer oder zu kurzer Hex' do
      # Kills removal of the \A/\z anchors (embedded) and of the {6} length.
      ['#fef3c7 ', ' #fef3c7', 'x#fef3c7', '#fef3c7x', '#fef3c7aa', '##fef3c7', '#fef3c'].each do |bad|
        expect(described_class.hex?(bad)).to be(false), "erwartet hex?(#{bad.inspect}) == false"
      end
    end
  end

  describe '.next_color' do
    it 'gibt bei leerem taken die erste Palette-Farbe' do
      expect(described_class.next_color([])).to eq(described_class::HEXES.first)
    end

    it 'gibt die erste NICHT vergebene Farbe' do
      taken = described_class::HEXES.first(2)
      expect(described_class.next_color(taken)).to eq(described_class::HEXES[2])
    end

    it 'ignoriert Nicht-Hex-Werte (OFF/nil) im taken' do
      # OFF/nil occupy no color -> the first palette color stays free.
      expect(described_class.next_color([described_class::OFF, nil])).to eq(described_class::HEXES.first)
    end

    it 'rotiert deterministisch, wenn alle Farben vergeben sind (statt nil)' do
      all = described_class::HEXES.dup
      expect(described_class.next_color(all)).to eq(described_class::HEXES[0])
      expect(described_class.next_color(all + [described_class::HEXES[0]])).to eq(described_class::HEXES[1])
    end
  end

  describe '.assign_defaults' do
    it 'weist Orgs ohne Eintrag distinkte Farben zu' do
      result = described_class.assign_defaults(existing_by_org_id: {}, org_ids: %w[a b c])
      expect(result.values_at('a', 'b', 'c')).to eq(described_class::HEXES.first(3))
      expect(result.values.uniq.size).to eq(3)
    end

    it 'laesst bestehende Farben UND OFF unangetastet (Idempotenz + Aus bleibt aus)' do
      existing = { 'a' => '#dbeafe', 'b' => described_class::OFF }
      result = described_class.assign_defaults(existing_by_org_id: existing, org_ids: %w[a b c])
      expect(result['a']).to eq('#dbeafe') # own color stays
      expect(result['b']).to eq(described_class::OFF) # Off stays Off (is NOT auto-colored)
      expect(described_class.hex?(result['c'])).to be(true) # only the new org gets a color
      # and specifically the first FREE one: #dbeafe is HEXES[2] (taken) -> c == HEXES[0].
      expect(result['c']).to eq(described_class::HEXES.first)
    end

    it 'nutzt bei voller Org-Zahl die GANZE Palette (jede Farbe genau einmal)' do
      # Positive iteration over the whitelist: if someone shrinks PALETTE, this breaks here.
      ids = Array.new(described_class::HEXES.size) { |i| "org#{i}" }
      result = described_class.assign_defaults(existing_by_org_id: {}, org_ids: ids)
      expect(result.values).to match_array(described_class::HEXES)
      expect(result.values.uniq.size).to eq(described_class::HEXES.size)
    end

    it 'ueberspringt eine bereits vergebene Palette-Farbe (taken-Buchfuehrung)' do
      existing = { 'a' => described_class::HEXES[0] }
      result = described_class.assign_defaults(existing_by_org_id: existing, org_ids: %w[a b])
      expect(result['b']).to eq(described_class::HEXES[1]) # NOT [0], that one is taken
    end

    it 'ist idempotent (zweiter Lauf aendert nichts)' do
      first = described_class.assign_defaults(existing_by_org_id: {}, org_ids: %w[a b])
      second = described_class.assign_defaults(existing_by_org_id: first, org_ids: %w[a b])
      expect(second).to eq(first)
    end

    it 'mutiert die Eingabe-Map nicht' do
      existing = { 'a' => '#dbeafe' }
      described_class.assign_defaults(existing_by_org_id: existing, org_ids: %w[a b])
      expect(existing).to eq({ 'a' => '#dbeafe' })
    end
  end

  describe '.effective_color' do
    let(:hex) { '#dbeafe' }

    it 'gibt nil bei <2 Orgs — auch wenn eine Farbe gesetzt ist (kein Unterscheidungsbedarf)' do
      expect(described_class.effective_color(setting: hex, org_count: 1)).to be_nil
      expect(described_class.effective_color(setting: hex, org_count: 0)).to be_nil
    end

    it 'gibt nil bei OFF (bewusst aus)' do
      expect(described_class.effective_color(setting: described_class::OFF, org_count: 5)).to be_nil
    end

    it 'gibt den Hex bei >=2 Orgs' do
      expect(described_class.effective_color(setting: hex, org_count: 2)).to eq(hex)
    end

    it 'gibt nil bei abwesendem Setting (nil)' do
      expect(described_class.effective_color(setting: nil, org_count: 2)).to be_nil
    end

    it 'Grenze: org_count 1 -> nil, 2 -> sichtbar' do
      expect(described_class.effective_color(setting: hex, org_count: 1)).to be_nil
      expect(described_class.effective_color(setting: hex, org_count: 2)).to eq(hex)
    end

    it 'gibt nil bei ungueltigem gespeichertem Wert (Resolver-Sicherheit, kein CSS-Leak)' do
      # Kills omission of the hex? guard at the return: a junk value must never come out as a color.
      ['banana', 'red', '#xyz', 123].each do |junk|
        expect(described_class.effective_color(setting: junk, org_count: 2)).to be_nil,
                                                                                "erwartet nil fuer #{junk.inspect}"
      end
    end

    it 'rendert JEDEN gueltigen Hex (auch ausserhalb der Palette) — Vertrag: zeigt das Gespeicherte' do
      # Deliberately documents: the resolver does NOT gate on palette membership.
      expect(described_class.effective_color(setting: '#abcdef', org_count: 2)).to eq('#abcdef')
    end
  end
end
