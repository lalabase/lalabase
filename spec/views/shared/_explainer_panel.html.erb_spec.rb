# frozen_string_literal: true

require 'rails_helper'

# Unit render of the shared plain-language explainer aside (first-time empty
# states). It resolves ALL texts from an i18n scope, so the two things worth
# guarding are: (1) the optional blocks (intro / not-box / reassure) key off
# key PRESENCE — a scope without `not_title` must not render an empty box —
# and (2) DE and EN never drift apart per scope, because the partial would
# then raise (or fall back) only in ONE language at runtime.
RSpec.describe 'shared/_explainer_panel', type: :view do
  # Mirrors the call sites (knowledge/tickets/time_sessions/meetings results
  # partials) — extend when a new area adopts the panel.
  let(:explainer_scopes) do
    %w[
      views.organisations.knowledge.index.explainer
      views.organisations.tickets.tickets_results.explainer
      views.organisations.time_sessions.index_table.explainer
      views.organisations.meetings.index.explainer
    ]
  end

  def render_panel(i18n_scope:, points:)
    render partial: 'shared/explainer_panel', locals: { i18n_scope: i18n_scope, points: points }
    Nokogiri::HTML.fragment(rendered)
  end

  it 'renders title, one icon bullet per point and the not-box (knowledge scope has one)' do
    doc = render_panel(i18n_scope: 'views.organisations.knowledge.index.explainer',
                       points: { files: 'file-earmark', notes: 'pencil', search: 'search', chat: 'robot' })

    expect(doc.at_css('h3').text.strip).to eq(I18n.t('views.organisations.knowledge.index.explainer.title'))
    expect(doc.css('ul li').size).to eq(4)
    expect(doc.at_css('i.bi-file-earmark')).not_to be_nil
    expect(doc.text).to include(I18n.t('views.organisations.knowledge.index.explainer.not_title'))
    expect(doc.text).to include(I18n.t('views.organisations.knowledge.index.explainer.not_body'))
  end

  it 'omits the optional blocks when the scope has no such keys (time_sessions scope)' do
    doc = render_panel(i18n_scope: 'views.organisations.time_sessions.index_table.explainer',
                       points: { capture: 'stopwatch', ticket: 'check2-square' })

    # No not-box (its distinctive inner container) and no italic reassure line.
    expect(doc.css('div.bg-cream-100')).to be_empty
    expect(doc.css('p.italic')).to be_empty
    expect(doc.css('ul li').size).to eq(2)
  end

  it 'keeps DE and EN explainer keys in sync for every adopting area' do
    explainer_scopes.each do |scope|
      de = I18n.t(scope, locale: :de)
      en = I18n.t(scope, locale: :en)

      expect(de).to be_a(Hash), "missing DE explainer block for #{scope}"
      expect(en).to be_a(Hash), "missing EN explainer block for #{scope}"
      expect(en.keys).to match_array(de.keys), "DE/EN explainer keys drift for #{scope}"
      expect(de.keys).to include(:title)
    end
  end
end
