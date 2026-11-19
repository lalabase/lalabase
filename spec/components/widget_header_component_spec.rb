# frozen_string_literal: true

require 'rails_helper'

# What: WidgetHeaderComponent — the single shared header for every overview/dashboard widget.
# Why:  This component IS the consistency mechanism (one definition, no per-widget drift) AND the
#       fix for the "title reads as passive" problem. The colour assertion is load-bearing: the
#       title must stay INK (text-cream-900); a regression back to the old muted text-cream-600
#       (which made the title indistinguishable from inner labels) must break this spec.
#       The title wears the section label (.section-label, F51), as the sidebar and the timeline
#       do, and nothing in front of it: the "//" marker was a leftover of an older
#       design and is gone.
RSpec.describe WidgetHeaderComponent, type: :component do
  it 'renders the title in ink in the shape of a section label, with no marker in front' do
    render_inline(described_class.new(title: 'Portfolio'))

    heading = page.find('h2')
    expect(heading.text.strip).to eq('Portfolio')
    expect(heading[:class].split).to include('section-label', 'leading-4', 'text-cream-900')
    expect(page).to have_no_css('h2 [aria-hidden]')
  end

  it 'renders an optional subtitle as a quiet, normal-case continuation of the title' do
    render_inline(described_class.new(title: 'Zeiten', subtitle: 'KW 26'))

    expect(page).to have_css('h2 span.normal-case.text-cream-600', text: '· KW 26')
  end

  it 'omits the subtitle span entirely when no subtitle is given' do
    render_inline(described_class.new(title: 'Zeiten'))

    expect(page).to have_no_css('h2 span.normal-case')
  end

  it 'renders the actions slot in a right-aligned wrapper when provided' do
    render_inline(described_class.new(title: 'Aufgaben')) do |header|
      header.with_actions { '<button id="view-all">Alle</button>'.html_safe }
    end

    expect(page).to have_css('div.shrink-0 #view-all')
  end

  it 'omits the actions wrapper when the slot is not filled' do
    render_inline(described_class.new(title: 'Aufgaben'))

    expect(page).to have_no_css('div.shrink-0')
  end
end
