# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoFormSectionComponent, type: :component do
  let(:title) { 'Test Section' }

  describe 'rendering' do
    it 'renders section with title' do
      render_inline(described_class.new(title: title)) { 'Section content' }

      expect(page).to have_css('.neo-form-section')
      expect(page).to have_css('.neo-form-section-title')
      expect(page).to have_content(title)
      expect(page).to have_content('Section content')
    end

    it 'renders with description when provided' do
      description = 'This is a test section description'
      render_inline(described_class.new(title: title, description: description)) { 'Content' }

      expect(page).to have_content(description)
      expect(page).to have_css('.neo-form-section-description')
    end

    it 'renders expanded by default' do
      render_inline(described_class.new(title: title)) { 'Content' }

      expect(page).to have_css('.neo-form-section-content.block')
      expect(page).not_to have_css('.neo-form-section-content.hidden')
    end

    it 'renders collapsed when expanded: false' do
      render_inline(described_class.new(title: title, expanded: false)) { 'Content' }

      expect(page).to have_css('.neo-form-section-content.hidden')
      expect(page).not_to have_css('.neo-form-section-content.block')
    end

    it 'renders collapsible controls when collapsible: true' do
      render_inline(described_class.new(title: title, collapsible: true)) { 'Content' }

      expect(page).to have_css('[data-controller="neo-form-section"]')
      expect(page).to have_css('[data-action="click->neo-form-section#toggle"]')
      expect(page).to have_css('.bi-chevron-up, .bi-chevron-down') # chevron icon
    end

    it 'does not render collapsible controls when collapsible: false' do
      render_inline(described_class.new(title: title, collapsible: false)) { 'Content' }

      expect(page).not_to have_css('.bi-chevron-up')
      expect(page).not_to have_css('.bi-chevron-down')
    end

    it 'renders with icon when provided' do
      render_inline(described_class.new(title: title, icon: 'gear')) { 'Content' }

      expect(page).to have_css('.bi-gear')
    end

    it 'renders different variants correctly' do
      render_inline(described_class.new(title: title, variant: :warning)) { 'Content' }

      expect(page).to have_css('.bg-yellow-50.border-yellow-500')
    end

    it 'renders different sizes correctly' do
      render_inline(described_class.new(title: title, size: :large)) { 'Content' }

      expect(page).to have_css('.p-8') # large padding
      expect(page).to have_css('.text-xl') # large title
    end

    it 'generates unique section id' do
      render_inline(described_class.new(title: 'My Test Section')) { 'Content' }

      expect(page).to have_css('[id*="section_my_test_section"]')
    end

    it 'uses custom id when provided' do
      render_inline(described_class.new(title: title, id: 'custom-section')) { 'Content' }

      expect(page).to have_css('#custom-section')
    end
  end

  describe 'variants' do
    it 'renders primary variant with correct styling' do
      render_inline(described_class.new(title: title, variant: :primary)) { 'Content' }

      expect(page).to have_css('.bg-lime-50.border-lime-500')
    end

    it 'renders danger variant with correct styling' do
      render_inline(described_class.new(title: title, variant: :danger)) { 'Content' }

      expect(page).to have_css('.bg-red-50.border-red-500')
    end

    it 'renders success variant with correct styling' do
      render_inline(described_class.new(title: title, variant: :success)) { 'Content' }

      expect(page).to have_css('.bg-green-50.border-green-500')
    end
  end

  describe 'accessibility' do
    it 'has proper semantic structure' do
      render_inline(described_class.new(title: title)) { 'Content' }

      expect(page).to have_css('section')
      expect(page).to have_css('h3') # title is h3
    end

    it 'maintains proper focus behavior for collapsible sections' do
      render_inline(described_class.new(title: title, collapsible: true)) { 'Content' }

      expect(page).to have_css('.cursor-pointer') # clickable header
      expect(page).to have_css('.hover\\:bg-cream-100') # warm hover feedback (Teil G)
    end
  end

  describe 'data attributes' do
    it 'includes correct Stimulus data attributes' do
      render_inline(described_class.new(title: title, collapsible: true, expanded: false)) { 'Content' }

      expect(page).to have_css('[data-controller="neo-form-section"]')
      expect(page).to have_css('[data-neo-form-section-expanded-value="false"]')
      expect(page).to have_css('[data-neo-form-section-collapsible-value="true"]')
    end

    it 'includes target attributes for Stimulus' do
      render_inline(described_class.new(title: title, collapsible: true)) { 'Content' }

      expect(page).to have_css('[data-neo-form-section-target="content"]')
      expect(page).to have_css('[data-neo-form-section-target="chevron"]')
    end
  end
end
