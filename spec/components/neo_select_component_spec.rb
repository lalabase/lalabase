# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoSelectComponent, type: :component do
  let(:name) { 'test_select' }
  let(:label) { 'Test Select' }
  let(:options) do
    [
      ['Option 1', 'option1'],
      ['Option 2', 'option2'],
      ['Option 3', 'option3']
    ]
  end

  describe 'rendering' do
    it 'renders select with options' do
      render_inline(described_class.new(name: name, label: label, options: options))

      expect(page).to have_css('.neo-select-wrapper')
      expect(page).to have_css('select.neo-select')
      expect(page).to have_content(label)
      expect(page).to have_css('option', count: 3)
      expect(page).to have_css('option[value="option1"]')
      expect(page).to have_css('option[value="option2"]')
      expect(page).to have_css('option[value="option3"]')
    end

    it 'renders with selected option' do
      render_inline(described_class.new(name: name, label: label, options: options, selected: 'option2'))

      expect(page).to have_css('option[value="option2"][selected]')
    end

    it 'renders with placeholder when provided' do
      placeholder = 'Choose an option'
      render_inline(described_class.new(
                      name: name,
                      label: label,
                      options: options,
                      placeholder: placeholder
                    ))

      expect(page).to have_css('option[value=""][disabled]')
      expect(page).to have_content(placeholder)
    end

    it 'renders disabled select when disabled: true' do
      render_inline(described_class.new(name: name, label: label, options: options, disabled: true))

      expect(page).to have_css('select[disabled]')
      expect(page).to have_css('.opacity-50')
    end

    it 'renders with description when provided' do
      description = 'Please select an option from the list'
      render_inline(described_class.new(
                      name: name,
                      label: label,
                      options: options,
                      description: description
                    ))

      expect(page).to have_content(description)
      expect(page).to have_css('.text-xs.text-gray-600')
    end

    it 'renders different sizes correctly' do
      render_inline(described_class.new(name: name, label: label, options: options, size: :large))

      expect(page).to have_css('.text-base.h-12') # large size
    end

    it 'renders required select with asterisk' do
      render_inline(described_class.new(name: name, label: label, options: options, required: true))

      expect(page).to have_css('select[required]')
      expect(page).to have_css('.after\\:content-\\[\\"\\*\\"\\]') # required asterisk
    end

    it 'includes Stimulus controller when interactive' do
      render_inline(described_class.new(name: name, label: label, options: options, interactive: true))

      expect(page).to have_css('[data-controller="neo-select"]')
      expect(page).to have_css('[data-action="change->neo-select#handleChange"]')
    end

    it 'includes custom dropdown arrow' do
      render_inline(described_class.new(name: name, label: label, options: options))

      expect(page).to have_css('.pointer-events-none')
      expect(page).to have_css('.border-t-black') # custom triangle arrow
    end
  end

  describe 'option formats' do
    it 'handles hash options correctly' do
      hash_options = {
        'First Option' => 'first',
        'Second Option' => 'second'
      }

      render_inline(described_class.new(name: name, label: label, options: hash_options))

      expect(page).to have_css('option[value="first"]')
      expect(page).to have_css('option[value="second"]')
      expect(page).to have_content('First Option')
      expect(page).to have_content('Second Option')
    end

    it 'handles array of hashes with text/value keys' do
      hash_array_options = [
        { text: 'Hash Option 1', value: 'hash1' },
        { text: 'Hash Option 2', value: 'hash2' }
      ]

      render_inline(described_class.new(name: name, label: label, options: hash_array_options))

      expect(page).to have_css('option[value="hash1"]')
      expect(page).to have_css('option[value="hash2"]')
      expect(page).to have_content('Hash Option 1')
      expect(page).to have_content('Hash Option 2')
    end

    it 'handles simple string array options' do
      string_options = %w[Apple Banana Cherry]

      render_inline(described_class.new(name: name, label: label, options: string_options))

      expect(page).to have_css('option[value="Apple"]')
      expect(page).to have_css('option[value="Banana"]')
      expect(page).to have_css('option[value="Cherry"]')
    end
  end

  describe 'accessibility' do
    it 'has proper labels and ids' do
      render_inline(described_class.new(name: name, label: label, options: options))

      select_id = page.find('select')[:id]
      expect(page).to have_css("label[for='#{select_id}']")
    end

    it 'supports keyboard navigation' do
      render_inline(described_class.new(name: name, label: label, options: options))

      expect(page).to have_css('select.cursor-pointer')
      expect(page).to have_css('.focus\\:ring-2')
    end
  end
end
