# frozen_string_literal: true

require 'rails_helper'

# What: NeoProjectLayoutHeaderComponent — thin wrapper binding the shared
#       NeoTitleBoxComponent for the tickets/knowledge list layouts.
# Why:  Guards the delegation contract: title and subtitle must flow through to
#       the unified header (normal-case h1 + stacked muted subtitle), and the
#       optional smart-folder description renders below the header.
RSpec.describe NeoProjectLayoutHeaderComponent, type: :component do
  let(:smart_folder_struct) { Struct.new(:description) }

  def render_header(active_smart_folder: nil)
    render_inline(described_class.new(
                    title: 'Tickets',
                    subtitle: 'Fakolith',
                    project: nil,
                    active_smart_folder: active_smart_folder
                  ))
  end

  it 'renders the unified header with title and stacked subtitle' do
    render_header

    expect(page).to have_css('h1.text-heading', text: 'Tickets')
    expect(page).to have_no_css('h1.uppercase')
    expect(page).to have_css('p.text-sm.text-muted', text: 'Fakolith')
  end

  it 'renders the smart folder description below the header when present' do
    render_header(active_smart_folder: smart_folder_struct.new('Alle offenen Tickets'))

    expect(page).to have_css('p', text: 'Alle offenen Tickets')
  end

  it 'omits the smart folder description when the folder has none' do
    render_header(active_smart_folder: smart_folder_struct.new(nil))

    expect(page).to have_no_css('p.opacity-50')
  end
end
