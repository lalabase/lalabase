# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Neo::Buttons::ButtonComponent with form', type: :component do
  include ActionView::Helpers::FormHelper
  include ActionView::Helpers::FormTagHelper
  include ActionView::Helpers::UrlHelper

  let(:component) { Neo::Buttons::ButtonComponent.new(**options) }
  let(:options) { {} }
  let(:content) { 'Delete' }

  def rendered_component
    render_inline(component) { content }
  end

  describe 'form rendering' do
    context 'with form hash' do
      let(:options) do
        {
          variant: :danger,
          icon: 'trash',
          form: {
            action: '/posts/1',
            method: :delete
          }
        }
      end

      it 'generates a form with hidden method field' do
        rendered_component

        # Check form structure
        expect(page).to have_css("form[action='/posts/1'][method='post']")
        expect(page).to have_css("form input[name='_method'][value='delete']", visible: false)

        # Check button inside form
        expect(page).to have_css("form button[type='submit']")
        expect(page).to have_css('form button i.bi.bi-trash')
        expect(page).to have_content('Delete')
      end
    end

    context 'with turbo confirm in form button' do
      let(:options) do
        {
          variant: :danger,
          confirm: 'Are you sure?',
          form: {
            action: '/posts/1',
            method: :delete
          }
        }
      end

      it 'adds turbo confirm to the form' do
        rendered_component

        # button_to uses form: { data: { turbo_confirm: ... } } internally
        expect(page).to have_css("form[data-turbo-confirm='Are you sure?']")
      end
    end

    context 'with interactive features in form button' do
      let(:options) do
        {
          variant: :danger,
          confirm: 'Really delete?',
          form: {
            action: '/posts/1',
            method: :delete
          }
        }
      end

      # The controller stays (loading state); the question is asked ONCE, by the
      # form. The button's own confirm asked a second time (until 26.10.2026).
      it 'applies Stimulus controller to the button and leaves the question to the form' do
        rendered_component

        expect(page).to have_css("form button[data-controller='neo-button']")
        expect(page).to have_css("form[data-turbo-confirm='Really delete?']")
        expect(page).to have_no_css('form button[data-neo-button-confirm-value]')
        expect(page).to have_css("form button[data-action='click->neo-button#handleClick']")
      end
    end

    context 'when used as a regular submit button in existing form' do
      let(:options) do
        {
          variant: :primary,
          type: 'submit',
          icon: 'check-lg'
        }
      end

      it 'renders as a submit button without wrapping form' do
        rendered_component

        # Should not create a form wrapper
        expect(page).not_to have_css('form')

        # Should render submit button
        expect(page).to have_css("button[type='submit']")
        expect(page).to have_css('button i.bi.bi-check-lg')
      end
    end
  end

  describe 'real-world scenarios' do
    context 'icon-only delete button with confirmation' do
      it 'creates a proper delete form with Neo::Buttons::IconButtonComponent' do
        component = Neo::Buttons::IconButtonComponent.new(
          variant: :danger,
          size: :medium,
          icon: 'trash',
          confirm: 'Möchten Sie diesen Eintrag wirklich löschen?',
          form: {
            action: '/organisations/1/projects/2/permissions/3',
            method: :delete
          }
        )
        render_inline(component)

        # Form structure
        expect(page).to have_css("form[action='/organisations/1/projects/2/permissions/3']")
        expect(page).to have_css("form input[name='_method'][value='delete']", visible: false)

        # Button with all features
        expect(page).to have_css("form button[type='submit']")
        expect(page).to have_css("form button[data-controller='neo-button']")
        # The form asks once; the button no longer asks a second time.
        expect(page).to have_css("form[data-turbo-confirm*='wirklich löschen']")
        expect(page).to have_no_css('form button[data-neo-button-confirm-value]')
        expect(page).to have_css('form button i.bi.bi-trash')

        # Icon only - no margins
        expect(page).not_to have_css('i.mr-2')
        expect(page).not_to have_css('i.ml-2')
      end
    end

    context 'add button with POST form' do
      let(:options) do
        {
          variant: :success,
          size: :medium,
          icon: 'plus-lg',
          type: 'submit',
          form: {
            action: '/organisations/1/projects/2/permissions',
            method: :post
          }
        }
      end

      it 'creates a POST form' do
        rendered_component

        # POST forms don't need _method field
        expect(page).to have_css("form[action='/organisations/1/projects/2/permissions'][method='post']")
        expect(page).not_to have_css("form input[name='_method']")

        # Button
        expect(page).to have_css("form button[type='submit']")
        expect(page).to have_css('form button i.bi.bi-plus-lg')
      end
    end
  end

  describe 'params + form-level data forwarding (enhancement)' do
    it 'renders form params as hidden fields (ButtonComponent)' do
      render_inline(Neo::Buttons::ButtonComponent.new(
                      variant: :danger,
                      form: { action: '/x', method: :delete, params: { subscription_id: 42, notification: { state: 'read' } } }
                    )) { 'Go' }

      expect(page).to have_css("form input[name='subscription_id'][value='42']", visible: false)
      expect(page).to have_css("form input[name='notification[state]'][value='read']", visible: false)
    end

    it 'renders form params as hidden fields (IconButtonComponent)' do
      render_inline(Neo::Buttons::IconButtonComponent.new(
                      variant: :ghost, icon: 'check',
                      form: { action: '/x', method: :patch, params: { notification: { state: 'read' } } }
                    ))

      expect(page).to have_css("form input[name='notification[state]'][value='read']", visible: false)
    end

    it 'merges form-level data onto the form (turbo_frame + turbo_confirm) with no neo-button double-wire' do
      render_inline(Neo::Buttons::ButtonComponent.new(
                      variant: :secondary,
                      form: { action: '/x', method: :patch, data: { turbo_frame: '_top', turbo_confirm: 'Sure?' } }
                    )) { 'Go' }

      expect(page).to have_css("form[data-turbo-frame='_top']")
      expect(page).to have_css("form[data-turbo-confirm='Sure?']")
      # No confirm: param → not interactive → button must not carry neo-button confirm wiring
      expect(page).not_to have_css("form button[data-controller='neo-button']")
    end

    it 'forwards title and aria-label to the form button (icon-only a11y)' do
      render_inline(Neo::Buttons::IconButtonComponent.new(
                      variant: :ghost, icon: 'check',
                      title: 'Mark as read', 'aria-label': 'Mark this as read',
                      form: { action: '/x', method: :patch }
                    ))

      expect(page).to have_css("form button[title='Mark as read']")
      expect(page).to have_css("form button[aria-label='Mark this as read']")
    end
  end
end
