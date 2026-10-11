# frozen_string_literal: true

require 'rails_helper'

# What: WidgetEmptyComponent — the shared "nothing to show" line for overview widget empty branches.
# Why:  The redesign's whole point is that emptiness is QUIET, not a prominent bordered box. These
#       assertions are the regression guard: re-introducing border/fill chrome must break the test.
RSpec.describe WidgetEmptyComponent, type: :component do
  it 'renders the message as a muted, centered line' do
    render_inline(described_class.new(message: 'Keine offenen Tickets'))

    expect(page).to have_css('div.text-cream-500.text-center', text: 'Keine offenen Tickets')
  end

  it 'is borderless and unfilled (not a boxed empty card)' do
    render_inline(described_class.new(message: 'Nichts zu tun'))

    expect(page).to have_no_css('.border')
    expect(page).to have_no_css('.bg-cream-50')
  end
end
