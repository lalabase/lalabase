# frozen_string_literal: true

require 'rails_helper'

# What: NeoViewSwitchComponent, the switch between the views of one page (the
#       tickets' Liste | Kanban, the time list's Liste | Übersicht, the inbox's
#       Chronologisch | Nach Ticket gebündelt, the roles' list and matrix).
# Type: Component spec.
# Why:  One form for every view switch (user, 2026-11-11): the icon pair
#       (designer, 09.09.2026). Two 30x30 tiles, 2px apart, no container tone,
#       inline SVG icons (no icon font), the active tile a breath of ink (5 %)
#       over whatever the head stands on, with the icon in ink, never in the
#       selected tone; the caption on every tile three ways: title,
#       aria-label, keyboard tooltip.
#       Until then the time list wore a groove (selected tone, soft shadow on
#       the plate) and the inbox a framed pair of its own.
RSpec.describe NeoViewSwitchComponent, type: :component do
  let(:links) do
    [
      { key: :list, icon: :list, title: 'Liste', active: false, path: '/times' },
      { key: :overview, icon: :bars, title: 'Übersicht', active: true, path: '/times?view=overview' }
    ]
  end

  let(:buttons) do
    [
      { key: :table, icon: :list, title: 'Liste', active: true, path: '/view_mode', method: :patch, params: { view_mode: 'table' } },
      { key: :kanban, icon: :kanban, title: 'Kanban', active: false, path: '/view_mode', method: :patch, params: { view_mode: 'kanban' } }
    ]
  end

  it 'renders links inside a nav named by the label, the active one marked aria-current' do
    render_inline(described_class.new(label: 'Ansicht', items: links))

    expect(page).to have_css("nav[aria-label='Ansicht']")
    expect(page).to have_css("a[href='/times?view=overview'][aria-current='page']")
    expect(page).to have_css("a[href='/times']:not([aria-current])")
  end

  it 'renders a button form per item when the method is not GET, disabled where asked' do
    items = [buttons.first, buttons.last.merge(disabled: true)]
    render_inline(described_class.new(label: 'Ansicht', items: items))

    expect(page).to have_css("div[role='group'][aria-label='Ansicht']")
    expect(page).to have_css("form[action='/view_mode'] input[name='view_mode'][value='kanban']", visible: :all)
    expect(page).to have_css("button[title='Kanban'][disabled]")
    expect(page.find("button[title='Kanban']")[:class]).to include('opacity-30')
    expect(page).to have_css("button[title='Liste'][aria-pressed='true']")
    expect(page).to have_css("button[title='Kanban'][aria-pressed='false']")
  end

  it 'renders the tiles without a groove, every icon as SVG, no visible word' do
    render_inline(described_class.new(label: 'Ansicht', items: buttons))

    group = page.find("div[role='group'][aria-label='Ansicht']")
    expect(group[:class]).to include('gap-0.5')
    expect(group[:class]).not_to match(/bg-|border|rounded|shadow/)
    expect(page).to have_css('button svg[stroke="currentColor"][stroke-width="1.7"][width="15"]', count: 2)
    expect(page).not_to have_css('i.bi')
    expect(page.text.strip).to eq('')
  end

  # The tint, not a tone: cream-100 was the designer's, and it is the shell's
  # own ground, so on the time list's head (on the shell, not on a white
  # column) the active tile could not be seen (2026-11-11).
  it 'tints the active tile with ink over any ground, never a cream tone, never the selected tone' do
    render_inline(described_class.new(label: 'Ansicht', items: links))

    active = page.find("a[title='Übersicht']")
    inactive = page.find("a[title='Liste']")
    expect(active[:class]).to include('bg-ink/5', 'text-ink', 'h-[30px]', 'w-[30px]', 'rounded-md')
    expect(active[:class]).not_to match(/bg-selected|bg-cream-|shadow|font-(medium|bold)|border/)
    expect(inactive[:class]).to include('text-cream-500', 'hover:bg-ink/5', 'focus-visible:bg-ink/5')
    expect(inactive[:class]).not_to match(%r{(^|\s)bg-(ink/5|cream-)})
  end

  it 'captions every tile three ways: title, aria-label and the keyboard tooltip text' do
    render_inline(described_class.new(label: 'Ansicht', items: links))

    %w[Liste Übersicht].each do |word|
      tile = page.find("a[title='#{word}']")
      expect(tile['aria-label']).to eq(word)
      expect(tile['data-tip']).to eq(word)
      expect(tile[:class]).to include('view-switch-tile')
    end
    css = Rails.root.join('app/assets/stylesheets/components/view_switch.css').read
    expect(css).to include('.view-switch-tile:focus-visible::after')
    expect(css).to include('content: attr(data-tip)')
    expect(Rails.root.join('app/assets/stylesheets/application.css').read).to include('require components/view_switch')
  end

  # Each sign is drawn once, here. The list is the same three strokes in every
  # switch; the others name what the second view shows.
  it 'draws every sign it knows, each a different drawing' do
    drawings = described_class::ICONS.keys.map do |icon|
      render_inline(described_class.new(label: 'Ansicht', items: [{ key: icon, icon: icon, title: icon.to_s, active: false, path: '/' }]))
      page.find('svg', visible: :all).native.inner_html
    end

    expect(described_class::ICONS.keys).to contain_exactly(:list, :kanban, :bars, :stack, :grid, :card, :tagged)
    expect(drawings.uniq.size).to eq(drawings.size)
  end

  # Every switch of a page head writes a preference and draws the whole page again:
  # its form leaves Turbo. The card of /people stands in the lane's frame beside a list
  # with its page and search, so its switch names that frame and keeps Turbo.
  it 'takes a button out of Turbo unless the item names the frame its answer replaces' do
    render_inline(described_class.new(label: 'Ansicht', items: buttons))

    forms = page.all('form', visible: :all)
    expect(forms.map { |form| [form['data-turbo'], form['data-turbo-frame']] }).to eq([['false', nil], ['false', nil]])

    framed = buttons.map { |item| item.merge(turbo_frame: 'all_people_card') }
    render_inline(described_class.new(label: 'Ansicht', items: framed))

    forms = page.all('form', visible: :all)
    expect(forms.map { |form| [form['data-turbo'], form['data-turbo-frame']] }).to eq([[nil, 'all_people_card'], [nil, 'all_people_card']])
    expect(forms.map { |form| form['class'] }).to eq(%w[h-full h-full])
  end

  it 'refuses a frame for a link, which would ignore it' do
    expect { described_class.new(label: 'Ansicht', items: [links.first.merge(turbo_frame: 'all_people_card')]) }
      .to raise_error(ArgumentError)
  end

  # The two signs of the card of /people, drawn like the others: straight strokes and
  # plain shapes, nothing curved (spec/architecture/one_icon_set_guard_spec.rb).
  it 'draws the card with a head and the lines with their squares from strokes and shapes only' do
    { card: %w[rect circle path], tagged: %w[path rect rect rect] }.each do |icon, shapes|
      render_inline(described_class.new(label: 'Ansicht', items: [{ key: icon, icon: icon, title: icon.to_s, active: false, path: '/' }]))
      drawing = page.find('svg', visible: :all)
      expect(drawing.all('*', visible: :all).map(&:tag_name)).to eq(shapes)
      expect(drawing.all('path', visible: :all).map { |path| path['d'] }).to all(match(/\A[MmLlHhVv\d.\s-]+\z/))
    end
  end

  it 'refuses an unknown icon and the retired variant' do
    expect { described_class.new(label: 'Ansicht', items: [links.first.merge(icon: :gallery)]) }.to raise_error(ArgumentError)
    expect { described_class.new(label: 'Ansicht', items: [links.first.merge(icon: 'bi-list-ul')]) }.to raise_error(ArgumentError)
    expect { described_class.new(label: 'Ansicht', items: links, variant: :groove) }.to raise_error(ArgumentError)
  end
end
