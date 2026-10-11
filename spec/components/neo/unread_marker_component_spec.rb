# frozen_string_literal: true

require 'rails_helper'

# What: Neo::UnreadMarkerComponent, the one marker for "unread notifications".
# Why:  Pins the contracts its callers lean on: zero renders nothing unless the
#       marker is a live Turbo/Stimulus target, the count caps at 99+, a dot
#       without a label is hidden from screen readers, and a caller's id/data/
#       class reach the element without replacing the marker's own.
RSpec.describe Neo::UnreadMarkerComponent, type: :component do
  it 'renders the count as a red pill' do
    render_inline(described_class.new(count: 3, label: '3 unread'))

    marker = page.find('[data-unread-marker="count"]')
    expect(marker.text).to eq('3')
    expect(marker[:class]).to include('bg-red-600', 'rounded-full')
    expect(marker[:title]).to eq('3 unread')
    expect(marker['aria-label']).to eq('3 unread')
  end

  it 'caps the count at 99+' do
    render_inline(described_class.new(count: 100))

    expect(page.find('[data-unread-marker]').text).to eq('99+')
  end

  it 'renders the count 99 as it is' do
    render_inline(described_class.new(count: 99))

    expect(page.find('[data-unread-marker]').text).to eq('99')
  end

  it 'renders nothing at zero' do
    render_inline(described_class.new(count: 0))

    expect(page.native.inner_html).to be_blank
  end

  it 'renders a hidden element at zero when live, as the next stream target' do
    render_inline(described_class.new(count: 0, live: true, id: 'target'))

    marker = page.find('#target', visible: :all)
    expect(marker[:class].split).to include('hidden')
  end

  it 'is visible when live and positive' do
    render_inline(described_class.new(count: 1, live: true))

    expect(page.find('[data-unread-marker]')[:class].split).not_to include('hidden')
  end

  it 'renders a dot without a number, labelled as an image' do
    render_inline(described_class.new(count: 4, variant: :dot, label: 'Unread'))

    dot = page.find('[data-unread-marker="dot"]')
    expect(dot.text).to be_empty
    expect(dot[:role]).to eq('img')
    expect(dot['aria-label']).to eq('Unread')
  end

  it 'hides an unlabelled dot from screen readers' do
    render_inline(described_class.new(count: 1, variant: :dot))

    expect(page.find('[data-unread-marker="dot"]')['aria-hidden']).to eq('true')
  end

  it 'keeps its own classes and data when the caller adds some' do
    render_inline(described_class.new(count: 2, class: 'ml-1', data: { notification_count_listener_target: 'indicator' }))

    marker = page.find('[data-unread-marker="count"]')
    expect(marker[:class].split).to include('ml-1', 'bg-red-600')
    expect(marker['data-notification-count-listener-target']).to eq('indicator')
  end

  it 'rejects an unknown variant' do
    expect { described_class.new(count: 1, variant: :badge) }.to raise_error(ArgumentError)
  end
end
