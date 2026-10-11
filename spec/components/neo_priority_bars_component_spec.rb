# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoPriorityBarsComponent, type: :component do
  def bars(level:, total:, **opts)
    render_inline(described_class.new(level: level, total: total, **opts))
  end

  it 'does not render for an unset (zero) level' do
    expect(bars(level: 0, total: 4).to_html).to be_blank
  end

  it 'renders `total` bars and fills exactly `level` of them' do
    result = bars(level: 3, total: 4)

    rects = result.css('rect')
    filled = rects.reject { |rect| rect['fill'] == described_class::EMPTY_COLOR }

    expect(rects.size).to eq(4)
    expect(filled.size).to eq(3)
  end

  it 'uses the configured option color as the filled accent' do
    result = bars(level: 4, total: 4, color: '#ef4444')

    expect(result.css('rect').first['fill']).to eq('#ef4444')
  end

  it 'falls back to a neutral fill when no color is configured' do
    result = bars(level: 2, total: 4)
    filled = result.css('rect').reject { |rect| rect['fill'] == described_class::EMPTY_COLOR }

    expect(filled.map { |rect| rect['fill'] }.uniq).to eq([described_class::FILLED_FALLBACK_COLOR])
  end

  it 'exposes an accessible label (form + text, never color alone)' do
    result = bars(level: 4, total: 4, label: 'Priorität: Dringend')

    expect(result.css('svg').first['aria-label']).to eq('Priorität: Dringend')
  end

  it 'caps the bar count at four for higher-resolution fields' do
    expect(bars(level: 5, total: 6).css('rect').size).to eq(4)
  end

  it 'scales the FILLED count into the cap and rounds up (level 5 of 6 -> 4 filled, level 3 of 6 -> 2)' do
    filled = lambda do |level, total|
      bars(level: level, total: total).css('rect').reject { |r| r['fill'] == described_class::EMPTY_COLOR }.size
    end

    expect(filled.call(6, 6)).to eq(4) # top level always fills all bars
    expect(filled.call(5, 6)).to eq(4) # ceil(5/6*4) = 4
    expect(filled.call(3, 6)).to eq(2) # ceil(3/6*4) = 2
    expect(filled.call(1, 6)).to eq(1) # clamp floor: a set level never shows 0 bars
  end
end
