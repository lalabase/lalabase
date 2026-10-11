# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BrandHelper, type: :helper do
  describe '#hex_to_rgb_channels' do
    it 'wandelt 6-stelligen Hex in space-separierte RGB-Kanaele' do
      # 0x25=37, 0x63=99, 0xeb=235 — exact arithmetic, kills a wrong base/slice.
      expect(helper.hex_to_rgb_channels('#2563eb')).to eq('37 99 235')
    end

    it 'funktioniert ohne fuehrendes #' do
      expect(helper.hex_to_rgb_channels('2563eb')).to eq('37 99 235')
    end

    it 'ist case-insensitiv' do
      expect(helper.hex_to_rgb_channels('#2563EB')).to eq('37 99 235')
    end

    it 'bildet die Grenzen Schwarz und Weiss exakt ab' do
      expect(helper.hex_to_rgb_channels('#000000')).to eq('0 0 0')
      expect(helper.hex_to_rgb_channels('#ffffff')).to eq('255 255 255')
    end

    it 'gibt nil bei nil / leer / fehlerhaft / eingebettet / falscher Laenge' do
      # kills the removal of the \A/\z anchors and the {6} length.
      [nil, '', '#12345', '#1234567', 'xyzxyz', '#12 34 56', 'rgb(1,2,3)',
       '#fef3c7 ', ' #fef3c7', 'x#fef3c7', '#fef3c7x', 123, :sym].each do |bad|
        expect(helper.hex_to_rgb_channels(bad)).to be_nil, "erwartet nil fuer #{bad.inspect}"
      end
    end
  end

  describe '#brand_style_for' do
    let(:org) { instance_double(Organisation) }

    it 'gibt nil bei fehlendem User oder fehlender Org' do
      expect(helper.brand_style_for(nil, org)).to be_nil
      expect(helper.brand_style_for(instance_double(User), nil)).to be_nil
    end

    # Since user-split cut 3 the resolver lives in the PORO: user.org_colors.effective_color.
    # `.with(org)` pins the arg fidelity: the helper must resolve the color for EXACTLY the
    # passed-in org — a mutant like effective_color(nil) (or a swapped org) would run
    # silently green with an arg-agnostic stub and would be a cross-org leak at render time.
    def user_with_effective_color(value)
      org_colors = instance_double(User::OrgColorSettings)
      allow(org_colors).to receive(:effective_color).with(org).and_return(value)
      instance_double(User, org_colors: org_colors)
    end

    it 'rendert das Inline-Override aus der effektiven Farbe (Resolver-getrieben)' do
      # 0x7c=124, 0x3a=58, 0xed=237
      user = user_with_effective_color('#7c3aed')
      expect(helper.brand_style_for(user, org)).to eq('--brand: 124 58 237;')
    end

    it 'gibt nil, wenn der Resolver nil liefert (≥2-Gate / OFF / nicht gesetzt)' do
      user = user_with_effective_color(nil)
      expect(helper.brand_style_for(user, org)).to be_nil
    end
  end
end
