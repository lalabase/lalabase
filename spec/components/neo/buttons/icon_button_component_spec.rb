# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Neo::Buttons::IconButtonComponent, type: :component do
  subject(:component) { described_class.new(**options) }

  let(:options) { { icon: 'pencil' } }

  def rendered_component
    render_inline(component)
  end

  describe 'basic rendering' do
    it 'renders a button with icon' do
      rendered_component

      expect(page).to have_css("button[type='button']")
      expect(page).to have_css('i.bi.bi-pencil')
    end

    it 'renders icon without margins' do
      rendered_component

      expect(page).not_to have_css('i.mr-2')
      expect(page).not_to have_css('i.ml-2')
    end

    it 'does not render a content span' do
      rendered_component

      expect(page).not_to have_css('[data-neo-button-target="content"]')
    end

    context 'with url' do
      let(:options) { { icon: 'pencil', url: '/test' } }

      it 'renders a link instead of button' do
        rendered_component

        expect(page).to have_css("a[href='/test']")
        expect(page).to have_css('i.bi.bi-pencil')
      end
    end

    context 'with title' do
      let(:options) { { icon: 'trash', title: 'Löschen' } }

      it 'passes title attribute' do
        rendered_component

        expect(page).to have_css("button[title='Löschen']")
      end
    end
  end

  describe 'variants' do
    Neo::Buttons::Base::VARIANTS.keys.each do |variant|
      context "when variant is #{variant}" do
        let(:options) { { icon: 'pencil', variant: variant } }

        it 'applies the correct variant classes' do
          rendered_component

          variant_classes = Neo::Buttons::Base::VARIANTS[variant]
          expect(page).to have_css("button[class*='#{variant_classes.split.first}']")
        end
      end
    end
  end

  describe 'sizes' do
    Neo::Buttons::Base::SIZES.keys.each do |size|
      context "when size is #{size}" do
        let(:options) { { icon: 'pencil', size: size } }

        it 'applies the correct size classes' do
          rendered_component

          size_classes = Neo::Buttons::Base::SIZES[size]
          expect(page).to have_css("button[class*='#{size_classes.split.first}']")
        end
      end
    end
  end

  describe 'disabled state' do
    let(:options) { { icon: 'pencil', disabled: true } }

    it 'adds disabled attribute and classes' do
      rendered_component

      expect(page).to have_css('button[disabled]')
      # The look rides on the attribute: a controller that clears it gets an enabled button.
      expect(page).to have_css('button.disabled\:opacity-50.disabled\:cursor-not-allowed.disabled\:pointer-events-none')
      expect(page).to have_no_css('button.pointer-events-none')
    end
  end

  describe 'loading state' do
    let(:options) { { icon: 'pencil', loading: true } }

    it 'adds disabled attribute and loading classes' do
      rendered_component

      expect(page).to have_css('button[disabled]')
      expect(page).to have_css('button.cursor-wait')
    end
  end

  describe 'interactive features' do
    context 'with confirmation' do
      let(:options) { { icon: 'trash', confirm: 'Are you sure?' } }

      it 'adds Stimulus controller and data attributes' do
        rendered_component

        expect(page).to have_css("button[data-controller='neo-button']")
        expect(page).to have_css("button[data-neo-button-confirm-value='Are you sure?']")
      end
    end
  end

  describe 'form integration' do
    let(:options) do
      {
        icon: 'trash',
        variant: :danger,
        form: {
          action: '/posts/1',
          method: :delete
        }
      }
    end

    it 'renders a form with button inside' do
      rendered_component

      expect(page).to have_css("form[action='/posts/1'][method='post']")
      expect(page).to have_css("form input[name='_method'][value='delete']", visible: false)
      expect(page).to have_css('form button[type="submit"]')
      expect(page).to have_css('i.bi.bi-trash')
    end
  end

  describe 'custom attributes' do
    let(:options) do
      {
        icon: 'gear',
        data: { turbo_method: :delete },
        class: 'custom-class',
        id: 'special-icon-button'
      }
    end

    it 'passes through custom attributes' do
      rendered_component

      expect(page).to have_css('button#special-icon-button')
      expect(page).to have_css("button[data-turbo-method='delete']")
      expect(page).to have_css('button.custom-class')
    end
  end
  # The sign button of the main action: 32 x 32, the plus a drawn stroke cross.
  describe 'the main action as a sign' do
    it 'draws the plus as an SVG cross at 18 px inside a 32 px square' do
      render_inline(described_class.new(variant: :primary, icon: 'plus-lg', title: 'New'))

      expect(page).to have_css('button.h-8.w-8.border-ink.rounded-lg svg[width="18"][height="18"] path[stroke="currentColor"]')
      expect(page).to have_no_css('i.bi-plus-lg')
    end

    it 'keeps the font glyph for every other icon' do
      render_inline(described_class.new(variant: :primary, icon: 'pencil', title: 'Edit'))

      expect(page).to have_css('button.border-ink i.bi-pencil')
    end
  end
end
