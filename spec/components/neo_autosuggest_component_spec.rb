# frozen_string_literal: true

require 'rails_helper'

# NeoAutosuggestComponent in its two modes. The client mode (meeting and time pickers) must
# render as before the server mode came in; the server mode (the ticket picker of the "Link"
# modal, doc/ticket_relations_plan.md, revision 4, §7) hands the controller its URL, the
# confirmed choice and the texts of its status line.
RSpec.describe NeoAutosuggestComponent, type: :component do
  let(:options) { [{ value: 't1', text: '#1 First' }, { value: 't2', text: '#2 Second' }] }

  describe 'client mode (no url)' do
    it 'renders the options, a readonly field and the chosen text, and no server values' do
      render_inline(described_class.new(name: 'ticket_id', options: options, selected: 't2'))

      root = page.find('[data-controller="neo-autosuggest"]', visible: :all)
      expect(root['data-neo-autosuggest-url-value']).to be_nil
      expect(page).to have_css('input[type="text"][readonly][value="#2 Second"]', visible: :all)
      expect(page).to have_css('[data-neo-autosuggest-target="option"][data-value="t1"]', visible: :all)
      expect(page).to have_css('[data-neo-autosuggest-target="option"][data-value=""]', visible: :all)
      expect(page).to have_css('input[type="hidden"][name="ticket_id"][value="t2"]', visible: :all)
      expect(page).to have_no_css('template', visible: :all)
    end
  end

  describe 'server mode (url)' do
    let(:url) { '/org/o1/ticket_lookups?exclude=t0' }

    def render_server(**overrides)
      render_inline(described_class.new(name: 'other_ticket_id', options: [], include_blank: false, url: url,
                                        input_id: 'picker', **overrides))
    end

    it 'hands the controller the URL and the texts of the status line, and lists nothing' do
      render_server

      root = page.find('[data-controller="neo-autosuggest"]', visible: :all)
      expect(root['data-neo-autosuggest-url-value']).to eq(url)
      expect(root['data-neo-autosuggest-hint-text-value']).to eq(I18n.t('components.neo_autosuggest.server.hint'))
      expect(root['data-neo-autosuggest-empty-text-value']).to eq(I18n.t('components.neo_autosuggest.server.empty'))
      expect(root['data-neo-autosuggest-error-text-value']).to eq(I18n.t('components.neo_autosuggest.server.error'))
      expect(page).to have_no_css('[data-neo-autosuggest-target="dropdown"] > [data-neo-autosuggest-target="option"]',
                                  visible: :all)
    end

    # Review round 4 of #944: a listbox may hold options only. The status line (hint,
    # searching, no results, failed) stands beside it, and the field controls the listbox.
    it 'keeps the status line out of the listbox' do
      render_server

      listbox = page.find('[role="listbox"]', visible: :all)
      expect(listbox).to have_no_css('[role="status"]', visible: :all)
      expect(page).to have_css('[data-neo-autosuggest-target="dropdown"] > [role="status"]', visible: :all)
      expect(page.find('input#picker', visible: :all)['aria-controls']).to eq(listbox[:id])
    end

    it 'renders an editable combobox the label can name' do
      render_server

      field = page.find('input#picker', visible: :all)
      expect(field[:readonly]).to be_nil
      expect(field[:role]).to eq('combobox')
      expect(field[:autocomplete]).to eq('off')
    end

    it 'shows the confirmed choice it was given, value and text, as after a refused save' do
      render_server(selected: 't7', selected_text: '#7 Login audit')

      root = page.find('[data-controller="neo-autosuggest"]', visible: :all)
      expect(root['data-neo-autosuggest-selected-value']).to eq('t7')
      expect(root['data-neo-autosuggest-selected-text-value']).to eq('#7 Login audit')
      expect(page).to have_css('input#picker[value="#7 Login audit"]', visible: :all)
      expect(page).to have_css('input[type="hidden"][name="other_ticket_id"][value="t7"]', visible: :all)
    end

    it 'starts empty without a choice' do
      render_server

      expect(page.find('input#picker', visible: :all).value.to_s).to eq('')
      expect(page).to have_css('input[type="hidden"][name="other_ticket_id"]', visible: :all)
    end

    it 'brings a template for the options the browser builds, marked as unselected' do
      render_server

      # A template's content is a fragment of its own for the parser, so the markup is read raw.
      template = rendered_content[%r{<template data-neo-autosuggest-target="optionTemplate">.*?</template>}m]
      expect(template).to include('data-slot="text"', 'data-slot="detail"', 'role="option"')
      expect(template).not_to include('bg-lime-200')
    end
  end
end
