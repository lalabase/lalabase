# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoInfoTagComponent, type: :component do
  context 'with default attributes' do
    it 'renders a basic info tag' do
      render_inline(described_class.new(text: 'Information'))

      expect(page).to have_css('span.inline-flex.items-center.gap-x-1\\.5.rounded-full.font-medium.border')
      expect(page).to have_text('Information')
      expect(page).to have_css('span.bg-blue-100.text-blue-900.border-blue-900') # default info variant
      expect(page).to have_css('i.bi.bi-info-circle-fill') # default icon
    end
  end

  context 'with different variants' do
    it 'renders with success variant' do
      render_inline(described_class.new(text: 'Success', variant: :success))
      expect(page).to have_css('span.bg-green-100.text-green-900.border-green-900')
      expect(page).to have_css('i.bi.bi-check-circle-fill')
    end

    it 'renders with warning variant' do
      render_inline(described_class.new(text: 'Warning', variant: :warning))
      expect(page).to have_css('span.bg-yellow-200.text-yellow-900.border-stroke')
      expect(page).to have_css('i.bi.bi-exclamation-triangle-fill')
    end

    it 'renders with danger variant' do
      render_inline(described_class.new(text: 'Danger', variant: :danger))
      expect(page).to have_css('span.bg-red-100.text-red-900.border-red-900')
      expect(page).to have_css('i.bi.bi-x-circle-fill')
    end

    it 'renders with processing variant' do
      render_inline(described_class.new(text: 'Processing', variant: :processing))
      expect(page).to have_css('span.bg-yellow-200.text-yellow-800.border-stroke')
      expect(page).to have_css('i.bi.bi-clock-fill')
    end

    it 'renders with neutral variant' do
      render_inline(described_class.new(text: 'Neutral', variant: :neutral))
      expect(page).to have_css('span.bg-gray-100.text-gray-800.border-gray-400')
      expect(page).to have_css('i.bi.bi-circle-fill')
    end
  end

  context 'with different sizes' do
    it 'renders small size' do
      render_inline(described_class.new(text: 'Small', size: :small))
      expect(page).to have_css('span.text-xs.px-2\\.5.py-1')
    end

    it 'renders medium size' do
      render_inline(described_class.new(text: 'Medium', size: :medium))
      expect(page).to have_css('span.text-sm.px-3.py-1\\.5')
    end

    it 'renders large size' do
      render_inline(described_class.new(text: 'Large', size: :large))
      expect(page).to have_css('span.text-base.px-4.py-2')
    end
  end

  context 'with custom icon' do
    it 'renders with custom icon' do
      render_inline(described_class.new(text: 'Custom', icon: 'star-fill'))
      expect(page).to have_css('i.bi.bi-star-fill')
    end
  end

  context 'with title' do
    it 'renders with title attribute' do
      render_inline(described_class.new(text: 'Info', title: 'This is a tooltip'))
      expect(page).to have_css("span[title='This is a tooltip']")
    end
  end

  context 'with animation' do
    it 'adds animation class for processing variant' do
      render_inline(described_class.new(text: 'Loading', variant: :processing, animated: true))
      expect(page).to have_css('i.inline-block.animate-spin')
    end

    it 'does not add animation class for other variants' do
      render_inline(described_class.new(text: 'Success', variant: :success, animated: true))
      expect(page).not_to have_css('i.animate-spin')
    end
  end

  context 'with custom classes' do
    it 'appends custom classes' do
      render_inline(described_class.new(text: 'Custom', class: 'custom-class'))
      expect(page).to have_css('span.custom-class')
    end
  end
end
