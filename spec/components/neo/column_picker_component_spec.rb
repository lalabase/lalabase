# frozen_string_literal: true

require 'rails_helper'

# What: Neo::ColumnPickerComponent, the panel of the column choice (doc/spaltenwahl_plan.md, S2).
# Type: component spec, rendered inline. The panel renders HIDDEN (the trigger opens
#   it), so every lookup reads hidden markup (visible: :all).
# Why: the rows must come in rank order with the ticked ones first, the boundary
#   must sit before the first ranked column that does not fit (and nowhere when
#   everything fits), number and title must stand at the top as fixed rows, and a
#   view the reader may not change must take no tick. Each of these is a place
#   where the panel would lie about the table.
RSpec.describe Neo::ColumnPickerComponent, type: :component do
  let(:available) do
    [
      { key: 'number', label: 'Nr.', type: 'number', required: true },
      { key: 'title', label: 'Titel', type: 'text', required: true },
      { key: 'assignees', label: 'Zugewiesen', type: 'users' },
      { key: 'tags', label: 'Tags', type: 'tags' },
      { key: 'created_at', label: 'Erstellt', type: 'datetime' },
      { key: 'custom_phase', label: 'Phase', type: 'select', custom: true }
    ]
  end
  let(:chosen) do
    [
      available[0].merge(rank: nil, min_width: 60), available[1].merge(rank: nil, min_width: 200),
      available[4].merge(rank: 1, min_width: 110), available[2].merge(rank: 2, min_width: 120)
    ]
  end

  def render_picker(fit: 2, editable: true)
    render_inline(described_class.new(available: available, chosen: chosen, view_name: 'Von Guido', fit: fit, editable: editable))
  end

  # The ranked rows and the separator, without the two fixed rows at the top.
  def list_items
    page.all('ul.column-picker__list > li[data-key], ul.column-picker__list > li[role="separator"]', visible: :all).map { |li| li['role'] == 'separator' ? 'separator' : li['data-key'] }
  end

  it 'lists number and title as fixed rows, then the ticked columns in rank order, then the rest in the project order' do
    render_picker
    keys = page.all('li.column-picker__row[data-key]', visible: :all).map { |row| row['data-key'] }
    expect(keys).to eq(%w[created_at assignees tags custom_phase])
    expect(page.all('li.column-picker__row[data-key] input[checked]', visible: :all).size).to eq(2)
    expect(page).to have_css('li[data-key="created_at"] input[checked]', visible: :all)
    expect(page).to have_no_css('li[data-key="tags"] input[checked]', visible: :all)

    fixed = page.all('li.column-picker__row--fixed', visible: :all)
    # The word "immer" went with the pin (designer, 07.09.2026): the fixed rows
    # carry a filled sign that cannot be pressed, and its title says "immer
    # sichtbar, nicht änderbar". Saying it twice in one row is once too often.
    expect(fixed.map { |li| li.text(:all).squish }).to eq(%w[Nr. Titel])
    expect(fixed).to all(have_css('.column-picker__pin--fixed', visible: :all))
    expect(page.all('li.column-picker__row--fixed input[checked][disabled]', visible: :all).size).to eq(2)
    expect(page).to have_no_css('li.column-picker__row--fixed[data-column-picker-target]', visible: :all)
    expect(page.all('ul.column-picker__list > li', visible: :all).first(2).map { |li| li[:class] }).to all(include('column-picker__row--fixed'))
  end

  # The sign is the icon font's pin, once per state, and aria-pressed picks the one that
  # shows (column_picker.css). The script only flips the attribute; it repaints nothing.
  it 'draws the pin from the icon font: both states on a button, the filled one on a fixed row' do
    render_picker
    pinnable = page.find('li[data-key="created_at"] button.column-picker__pin', visible: :all)

    expect(pinnable).to have_css('i.bi.bi-pin.column-picker__pin-icon--off[aria-hidden="true"]', visible: :all)
    expect(pinnable).to have_css('i.bi.bi-pin-fill.column-picker__pin-icon--on[aria-hidden="true"]', visible: :all)
    fixed = page.all('li.column-picker__row--fixed', visible: :all)
    expect(fixed.size).to eq(2)
    expect(fixed).to all(have_css('.column-picker__pin--fixed i.bi.bi-pin-fill', visible: :all))
    expect(page).to have_no_css('svg', visible: :all)
  end

  it 'marks a pinned column as pressed, with the same two signs' do
    chosen[2] = chosen[2].merge(pinned: true)
    render_picker
    pinned = page.find('li[data-key="created_at"] button.column-picker__pin[aria-pressed="true"]', visible: :all)

    expect(pinned).to have_css('i.bi-pin.column-picker__pin-icon--off', visible: :all)
    expect(pinned).to have_css('i.bi-pin-fill.column-picker__pin-icon--on', visible: :all)
    expect(page).to have_css('li[data-key="assignees"] button.column-picker__pin[aria-pressed="false"]', visible: :all)
  end

  # Which of the two signs shows is decided in the stylesheet, and no rendered markup can
  # tell. Losing the rule shows both signs, swapping its halves shows the wrong one.
  it 'lets aria-pressed pick the sign in the stylesheet' do
    css = Rails.root.join('app/assets/stylesheets/components/column_picker.css').read

    expect(css.gsub(/\s+/, ' ')).to include(
      '.column-picker__pin[aria-pressed="true"] .column-picker__pin-icon--off, ' \
      '.column-picker__pin:not([aria-pressed="true"]) .column-picker__pin-icon--on { display: none; }'
    )
  end

  it 'carries the minimum width of every row for the fit rule' do
    render_picker
    expect(page.find('li[data-key="assignees"]', visible: :all)['data-min']).to eq('120')
    expect(page.find('li[data-key="custom_phase"]', visible: :all)['data-min']).to eq('110')
  end

  it 'puts the boundary before the first ranked column that does not fit' do
    render_picker(fit: 1)
    expect(list_items.first(3)).to eq(%w[created_at separator assignees])
    expect(page).to have_css('li[role="separator"]:not([hidden])', text: 'ab hier reicht die Breite nicht', visible: :all)
  end

  it 'puts the boundary at the very top when nothing beyond number and title fits' do
    render_picker(fit: 0)
    expect(list_items.first(2)).to eq(%w[separator created_at])
  end

  it 'keeps the boundary hidden when everything fits' do
    render_picker(fit: 2)
    expect(page).to have_css('li[role="separator"][hidden]', visible: :all)
    expect(page).to have_no_css('li[role="separator"]:not([hidden])', visible: :all)
  end

  it 'names the view it saves into, with the status line empty' do
    render_picker
    expect(page).to have_css('.column-picker__foot strong', text: 'Von Guido', visible: :all)
    expect(page).to have_css('[data-column-picker-target="status"][hidden]', visible: :all)
    expect(page).to have_no_text('nur lesbar')
  end

  it 'shows a read-only view with its rows, but no tick to take and no row to move' do
    render_picker(editable: false)
    expect(page).to have_css('li.column-picker__row[data-key]', count: 4, visible: :all)
    expect(page).to have_css('li.column-picker__row[data-key] input[disabled]', count: 4, visible: :all)
    expect(page).to have_no_css('li.column-picker__row[data-key][tabindex="0"]', visible: :all)
    expect(page).to have_css('li.column-picker__row[data-key][aria-disabled="true"]', count: 4, visible: :all)
    expect(page).to have_text(I18n.t('components.column_picker.read_only'))
  end

  it 'offers "für alle Ansichten übernehmen" as a form when it has an address for it, and not otherwise' do
    render_inline(described_class.new(available: available, chosen: chosen, view_name: 'Von Guido', fit: 2, apply_all_url: '/apply'))
    expect(page).to have_css('form.column-picker__apply[action="/apply"] button[type="submit"]', text: 'für alle Ansichten übernehmen', visible: :all)
    expect(page).to have_css('form.column-picker__apply input[name="_method"][value="patch"]', visible: :all)

    render_picker
    expect(page).to have_no_css('form.column-picker__apply', visible: :all)
  end
end
