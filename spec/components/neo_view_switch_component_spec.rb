# frozen_string_literal: true

require 'rails_helper'

# What: NeoViewSwitchComponent, the switch between the views of one page (the
#       tickets' Tabelle | Kanban, the time list's Übersicht | Liste).
# Type: Component spec.
# Why:  One look for both places, and the hooks the request specs rely on:
#       aria-label on the box, aria-current on the active link, the icon (or an
#       optional word label) as the visible label, title as the spoken name.
RSpec.describe NeoViewSwitchComponent, type: :component do
  let(:items) do
    [
      { key: :overview, icon: 'bi-table', title: 'Übersicht', active: true, path: '/times?view=overview' },
      { key: :list, icon: 'bi-list-ul', title: 'Liste', active: false, path: '/times' }
    ]
  end

  it 'renders links inside a nav named by the label, the active one marked aria-current' do
    render_inline(described_class.new(label: 'Ansicht', items: items))

    expect(page).to have_css("nav[aria-label='Ansicht']")
    expect(page).to have_css("a[href='/times?view=overview'][aria-current='page']")
    expect(page).to have_css("a[href='/times']:not([aria-current])")
  end

  it 'shows the icon and speaks the title' do
    render_inline(described_class.new(label: 'Ansicht', items: items))

    expect(page).to have_css('a[title="Übersicht"] i.bi-table[aria-hidden="true"]')
    expect(page).to have_css('a[title="Übersicht"] span.sr-only', text: 'Übersicht', visible: :all)
  end

  it 'shows the word when the item carries a label, without an icon' do
    labeled = items.map { |item| item.merge(label: item[:title]) }
    render_inline(described_class.new(label: 'Ansicht', items: labeled))

    expect(page).to have_css("a[href='/times?view=overview'] span", text: 'Übersicht')
    expect(page).not_to have_css('a i.bi-table')
  end

  it 'fills the active segment and leaves the other plain' do
    render_inline(described_class.new(label: 'Ansicht', items: items))

    expect(page.find("a[href='/times?view=overview']")[:class]).to include('bg-surface-raised')
    expect(page.find("a[href='/times']")[:class]).not_to include('bg-surface-raised')
  end

  it 'renders a button form per item when the method is not GET, disabled where asked' do
    buttons = [
      { key: :table, icon: 'bi-table', title: 'Tabelle', active: true, path: '/view_mode', method: :patch, params: { view_mode: 'table' } },
      { key: :kanban, icon: 'bi-kanban', title: 'Kanban', active: false, path: '/view_mode', method: :patch, params: { view_mode: 'kanban' }, disabled: true }
    ]
    render_inline(described_class.new(label: 'Ansicht', items: buttons))

    expect(page).to have_css("div[role='group'][aria-label='Ansicht']")
    expect(page).to have_css("form[action='/view_mode'] input[name='view_mode'][value='kanban']", visible: :all)
    expect(page).to have_css("button[title='Kanban'][disabled]")
    expect(page.find("button[title='Kanban']")[:class]).to include('opacity-30')
    expect(page).to have_css("button[title='Tabelle'][aria-pressed='true']")
  end

  # The icon pair (designer, 09.09.2026): two 30x30 tiles, 2px apart, no
  # container tone, inline SVG icons (no icon font), the active tile in the
  # neighbours' hover tone with the icon in ink and never in the selected tone;
  # the caption on every tile three ways: title, aria-label, keyboard tooltip.
  describe 'the icon pair' do
    let(:pair) do
      [
        { key: :table, icon: :list, title: 'Liste', active: true, path: '/view_mode', method: :patch, params: { view_mode: 'table' } },
        { key: :kanban, icon: :kanban, title: 'Kanban', active: false, path: '/view_mode', method: :patch, params: { view_mode: 'kanban' } }
      ]
    end

    it 'renders two tiles without a groove, both icons as SVG, no visible word, both always there' do
      render_inline(described_class.new(label: 'Ansicht', items: pair, variant: :icon_pair))

      group = page.find("div[role='group'][aria-label='Ansicht']")
      expect(group[:class]).to include('gap-0.5')
      expect(group[:class]).not_to include('bg-selected')
      expect(page).to have_css('button svg[stroke="currentColor"][stroke-width="1.7"][width="15"]', count: 2)
      expect(page).not_to have_css('button i.bi')
      expect(page.text.strip).to eq('')
    end

    it 'tones the active tile with the hover tone and ink, never the selected tone, and marks it pressed' do
      render_inline(described_class.new(label: 'Ansicht', items: pair, variant: :icon_pair))

      active = page.find("button[title='Liste']")
      inactive = page.find("button[title='Kanban']")
      expect(active[:class]).to include('bg-cream-100', 'text-ink', 'h-[30px]', 'w-[30px]', 'rounded-md')
      expect(active[:class]).not_to match(/bg-selected|bg-cream-200|shadow|font-(medium|bold)|border/)
      expect(active['aria-pressed']).to eq('true')
      expect(inactive[:class]).to include('text-cream-500', 'hover:bg-cream-100', 'focus-visible:bg-cream-100')
      expect(inactive[:class]).not_to match(/(^|\s)bg-cream-100(\s|$)/)
      expect(inactive['aria-pressed']).to eq('false')
    end

    it 'captions every tile three ways: title, aria-label and the keyboard tooltip text' do
      render_inline(described_class.new(label: 'Ansicht', items: pair, variant: :icon_pair))

      %w[Liste Kanban].each do |word|
        tile = page.find("button[title='#{word}']")
        expect(tile['aria-label']).to eq(word)
        expect(tile['data-tip']).to eq(word)
        expect(tile[:class]).to include('view-switch-tile')
      end
      css = Rails.root.join('app/assets/stylesheets/components/view_switch.css').read
      expect(css).to include('.view-switch-tile:focus-visible::after')
      expect(css).to include('content: attr(data-tip)')
      expect(Rails.root.join('app/assets/stylesheets/application.css').read).to include('require components/view_switch')
    end

    it 'refuses an unknown variant and an unknown icon' do
      expect { described_class.new(label: 'Ansicht', items: pair, variant: :pill) }.to raise_error(ArgumentError)
      expect { render_inline(described_class.new(label: 'Ansicht', items: [pair.first.merge(icon: :grid)], variant: :icon_pair)) }
        .to raise_error(ArgumentError)
    end
  end
end
