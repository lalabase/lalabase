# frozen_string_literal: true

require 'rails_helper'

# What: WidgetHeaderComponent — the single shared header for every overview/dashboard widget.
# Why:  This component IS the consistency mechanism (one definition, no per-widget drift) AND the
#       fix for the "title reads as passive" problem. The colour assertions are load-bearing: the
#       title must stay INK (text-cream-900) and the "//" marker cobalt — a regression back to the
#       old muted text-cream-600 (which made the title indistinguishable from inner labels) must
#       break this spec, not slip through silently.
RSpec.describe WidgetHeaderComponent, type: :component do
  it 'renders the title in ink with a cobalt "//" accent marker' do
    render_inline(described_class.new(title: 'Portfolio'))

    expect(page).to have_css('h2.font-mono.uppercase.text-cream-900', text: '// Portfolio')
    expect(page).to have_css('h2 span.text-cobalt-600[aria-hidden]', text: '//')
  end

  it 'renders an optional subtitle as a quiet, normal-case continuation of the title' do
    render_inline(described_class.new(title: 'Zeiten', subtitle: 'KW 26'))

    expect(page).to have_css('h2 span.normal-case.text-cream-600', text: '— KW 26')
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
