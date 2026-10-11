# frozen_string_literal: true

require 'rails_helper'

# The billing "Bezug" column and the time list draw their subject glyphs from
# TimeSessionsHelper::SUBJECT_ICONS. Those glyphs are deliberately the ones the
# project sidebar uses for the same areas, so the icon a user learned in the
# navigation is the icon they meet again next to a booked time.
#
# The two lists are separate constants on purpose — the helper must not carry a
# load-time dependency on a ViewComponent — and that is exactly the kind of pair
# that drifts in silence: someone restyles the sidebar, and the billing column
# keeps teaching the old vocabulary with nothing failing. This guard fails the
# moment the two disagree.
RSpec.describe 'Subject glyphs stay in sync with the project navigation' do
  def sidebar_icon(tab)
    NeoSidebarProjectItemComponent::NAV_ITEMS.find { |item| item[:tab] == tab }&.fetch(:icon)
  end

  it 'uses the sidebar glyph for tickets' do
    expect(TimeSessionsHelper::SUBJECT_ICONS.fetch(:ticket)).to eq(sidebar_icon('tickets'))
  end

  it 'uses the sidebar glyph for meetings' do
    expect(TimeSessionsHelper::SUBJECT_ICONS.fetch(:meeting)).to eq(sidebar_icon('meetings'))
  end
end
