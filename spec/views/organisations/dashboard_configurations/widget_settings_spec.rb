# frozen_string_literal: true

require 'rails_helper'

# Contract spec for the single source of the per-widget settings fields
# (_widget_settings). The inline editor's reindex depends on EXACTLY these
# name="rows[i][widgets][j]..." attributes plus a matching data-name-suffix, so this
# pins the serialization shape per widget type. If a name drifts, the saved layout
# silently loses settings — this catches it without a browser.
RSpec.describe 'organisations/dashboard_configurations/_widget_settings', type: :view do
  folder_struct = Struct.new(:id, :name)
  define_method(:folder) { |id, name| folder_struct.new(id, name) }

  def render_settings(widget_data, smart_folders: [])
    render partial: 'organisations/dashboard_configurations/widget_settings',
           locals: { row_idx: 2, slot_idx: 1, widget_data: widget_data, smart_folders: smart_folders }
    rendered
  end

  it 'renders recent_tickets display + period with the exact name + suffix' do
    html = render_settings({ 'key' => 'recent_tickets', 'display' => 'list', 'period' => 'this_week' })

    expect(html).to include('name="rows[2][widgets][1][display]"')
    expect(html).to include('data-name-suffix="[display]"')
    expect(html).to include('name="rows[2][widgets][1][period]"')
    expect(html).to include('data-name-suffix="[period]"')
    # selected reflects the persisted widget_data
    expect(html).to match(/<option value="list" selected[^>]*>/)
    expect(html).to match(/<option value="this_week" selected[^>]*>/)
  end

  it 'renders smart_folder_tickets folder select with the exact name + suffix' do
    folders = [folder('abc-123', 'Bugs'), folder('def-456', 'Done')]
    html = render_settings({ 'key' => 'smart_folder_tickets', 'folder_id' => 'def-456' }, smart_folders: folders)

    expect(html).to include('name="rows[2][widgets][1][folder_id]"')
    expect(html).to include('data-name-suffix="[folder_id]"')
    expect(html).to match(%r{<option value="def-456" selected[^>]*>Done</option>})
  end

  it 'renders stats_cards card_keys + card_settings with the exact names + suffixes' do
    html = render_settings({ 'key' => 'stats_cards',
                             'cards' => [{ 'key' => 'tickets', 'period' => 'this_month' },
                                         { 'key' => 'open_hours', 'period' => 'today', 'scope' => 'mine' }] })

    expect(html).to include('name="rows[2][widgets][1][card_keys][]"')
    expect(html).to include('data-name-suffix="[card_keys][]"')
    expect(html).to include('name="rows[2][widgets][1][card_settings][tickets][period]"')
    expect(html).to include('data-name-suffix="[card_settings][tickets][period]"')
    # open_hours supports scope → scope select present
    expect(html).to include('name="rows[2][widgets][1][card_settings][open_hours][scope]"')
  end

  it 'checks only the enabled cards (the rest are unchecked + disabled)' do
    html = render_settings({ 'key' => 'stats_cards', 'cards' => [{ 'key' => 'tickets' }] })
    doc = Nokogiri::HTML.fragment(html)

    tickets = doc.at_css("input[value='tickets'][type='checkbox']")
    notes   = doc.at_css("input[value='notes'][type='checkbox']")
    expect(tickets['checked']).to eq('checked')
    expect(notes['checked']).to be_nil
    # a disabled card's period select must not submit (disabled), so it can't pollute the layout
    notes_period = doc.at_css("select[name='rows[2][widgets][1][card_settings][notes][period]']")
    expect(notes_period['disabled']).to eq('disabled')
  end

  it 'renders nothing for a widget without settings' do
    html = render_settings({ 'key' => 'team_members' })
    expect(html.strip).to be_empty
  end
end
