# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organisations::Team::AccessCellComponent, type: :component do
  describe 'view mode (pill)' do
    it 'encodes the level with BOTH an icon and a text label (not colour alone)' do
      render_inline(described_class.new(area: :tickets, level: 'read_write'))

      expect(page).to have_css('i.bi-pencil')              # icon
      expect(page).to have_text('Schreiben')               # text label (a11y: not colour-only)
    end

    it 'renders no_access as a neutral dash, never red' do
      render_inline(described_class.new(area: :tickets, level: 'no_access'))

      expect(page).to have_css('i.bi-dash-lg')
      expect(page).to have_text('Kein Zugriff')
      expect(page).to have_no_css('.bg-red-500')
    end

    it 'marks an inherited cell as locked' do
      render_inline(described_class.new(area: :tickets, level: 'read_write', inherited: true))

      expect(page).to have_css('i.bi-lock-fill')
      expect(page).to have_css('[title]', text: '')
    end

    it 'shows no lock when the cell is an explicit (non-inherited) grant' do
      render_inline(described_class.new(area: :tickets, level: 'read_only', inherited: false))

      expect(page).to have_no_css('i.bi-lock-fill')
    end
  end

  describe 'edit mode (segmented control)' do
    subject(:render!) do
      render_inline(described_class.new(area: :chats, level: 'read_only', mode: :edit, user_id: 'u1'))
    end

    it 'renders a labelled radio group with one radio per level' do
      render!

      expect(page).to have_css('[role="radiogroup"]')
      expect(page).to have_css("input[type=radio][name='project_permission[chats_access]']", count: 3, visible: :all)
    end

    it 'pre-checks the current level only' do
      render!

      expect(page).to have_css("input[value='read_only'][checked]", visible: :all)
      expect(page).to have_no_css("input[value='read_write'][checked]", visible: :all)
    end

    it 'wires each radio to mark the form dirty' do
      render!

      expect(page).to have_css("input[data-action='change->team-member-edit#markDirty']", count: 3, visible: :all)
    end
  end
end
