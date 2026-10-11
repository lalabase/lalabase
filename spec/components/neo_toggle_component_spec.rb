# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoToggleComponent, type: :component do
  let(:name) { 'test_toggle' }
  let(:label) { 'Test Toggle' }

  describe 'rendering' do
    it 'renders unchecked toggle by default' do
      render_inline(described_class.new(name: name, label: label))

      expect(page).to have_css('.neo-toggle-wrapper')
      expect(page).to have_css('input[type="checkbox"]', visible: false)
      expect(page).to have_css('.neo-toggle-label')
      expect(page).to have_content(label)
      expect(page).to have_css('.bg-gray-100') # unchecked state
    end

    it 'renders checked toggle when checked: true' do
      render_inline(described_class.new(name: name, label: label, checked: true))

      expect(page).to have_css('input[type="checkbox"][checked]', visible: false)
      expect(page).to have_css('.bg-cobalt-600') # checked state: cobalt track (F7)
      # The inline style wins over the class in the browser, so it must carry the same token.
      expect(page).to have_css('label[style*="rgb(var(--cobalt-600))"]')
      expect(page).not_to have_css('.bg-lime-200') # lime belongs to the primary action only
    end

    it 'renders disabled toggle when disabled: true' do
      render_inline(described_class.new(name: name, label: label, disabled: true))

      expect(page).to have_css('input[type="checkbox"][disabled]', visible: false)
      expect(page).to have_css('.opacity-50')
    end

    it 'renders with description when provided' do
      description = 'This is a test toggle description'
      render_inline(described_class.new(name: name, label: label, description: description))

      expect(page).to have_content(description)
      expect(page).to have_css('.text-xs.text-gray-600')
    end

    it 'renders different sizes correctly' do
      render_inline(described_class.new(name: name, label: label, size: :large))

      expect(page).to have_css('.h-7.w-12') # large size
    end

    it 'includes Stimulus controller when interactive' do
      render_inline(described_class.new(name: name, label: label, interactive: true))

      expect(page).to have_css('[data-controller="neo-toggle"]')
      expect(page).to have_css('[data-action="change->neo-toggle#toggle"]')
    end

    it 'generates proper form name and hidden input' do
      render_inline(described_class.new(name: name, label: label))

      expect(page).to have_css('input[type="hidden"][name="test_toggle"][value="0"]', visible: :all)
      expect(page).to have_css('input[type="checkbox"][name="test_toggle"][value="1"]', visible: false)
    end

    it 'handles complex nested names correctly' do
      complex_name = 'preferences[ticket_commented][email][enabled]'
      render_inline(described_class.new(name: complex_name, label: label))

      expect(page).to have_css("input[name='#{complex_name}']")
    end
  end

  describe 'accessibility' do
    it 'has proper labels and ids' do
      render_inline(described_class.new(name: name, label: label))

      toggle_id = page.find('input[type="checkbox"]', visible: false)[:id]
      expect(page).to have_css("label[for='#{toggle_id}']")
    end

    it 'is keyboard accessible' do
      render_inline(described_class.new(name: name, label: label))

      expect(page).to have_css('.cursor-pointer')
      expect(page).to have_css('.focus-within\\:ring-2')
    end
  end
end
