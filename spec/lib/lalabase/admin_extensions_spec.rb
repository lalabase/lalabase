# frozen_string_literal: true

require 'rails_helper'

# The registry behind the slots of the instance admin (doc/oss_core_split_plan.md
# 5.2, slice S2). Every example runs inside with_empty_registry, so what the
# application registered at boot is back afterwards.
RSpec.describe Lalabase::AdminExtensions do
  around { |example| described_class.with_empty_registry { example.run } }

  it 'answers nothing for a slot nobody registered for' do
    expect(described_class.partials_for(:user_sections)).to eq([])
  end

  it 'keeps registrations per slot, in the order they came' do
    described_class.register(:user_sections, partial: 'a/first')
    described_class.register(:user_sections, partial: 'a/second')
    described_class.register(:organisation_header, partial: 'a/other')

    expect(described_class.partials_for(:user_sections)).to eq(%w[a/first a/second])
    expect(described_class.partials_for(:organisation_header)).to eq(%w[a/other])
  end

  # to_prepare runs again after every code reload; a second run must not render
  # a section twice.
  it 'registers the same partial only once' do
    2.times { described_class.register(:user_sections, partial: 'a/first') }

    expect(described_class.partials_for(:user_sections)).to eq(%w[a/first])
  end

  # The reason the slot list is closed: a typo would otherwise render nothing, on
  # a page where nothing is a legitimate state.
  it 'refuses an unknown slot when registering and when reading' do
    expect { described_class.register(:user_section, partial: 'a/first') }
      .to raise_error(described_class::UnknownSlot, /user_section/)
    expect { described_class.partials_for(:user_section) }
      .to raise_error(described_class::UnknownSlot)
  end

  it 'hands out a frozen list, so a caller cannot register by accident' do
    described_class.register(:user_sections, partial: 'a/first')

    expect(described_class.partials_for(:user_sections)).to be_frozen
  end

  describe '.with_empty_registry' do
    it 'restores the previous registrations, also when the block raises' do
      described_class.register(:user_sections, partial: 'a/first')

      expect do
        described_class.with_empty_registry do
          expect(described_class.partials_for(:user_sections)).to eq([])
          raise 'boom'
        end
      end.to raise_error('boom')

      expect(described_class.partials_for(:user_sections)).to eq(%w[a/first])
    end
  end
end
