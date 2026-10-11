# frozen_string_literal: true

# What this holds: shared/_ruled_rows is the ONE owner of the filler rows that
# rule a short list page to its size (doc/wissen_als_bahn_plan.md, section 13,
# D8). The colspan is the reason the partial exists: a row spanning one cell
# draws a dash instead of a line, which is what cost the ticket table its
# ruling in #768. The request specs of the two callers hold the count against
# their head; this one holds the partial's own contract.
require 'rails_helper'

RSpec.describe 'shared/_ruled_rows', type: :view do
  def render_rows(**locals)
    render partial: 'shared/ruled_rows', locals: locals
    Nokogiri::HTML.fragment(rendered)
  end

  it 'renders one row per missing line, spanning the given cells, hidden from readers' do
    rows = render_rows(missing: 3, colspan: 5).css('tr')

    expect(rows.size).to eq(3)
    expect(rows).to all(satisfy('carry the ruled-line marker') { |row| row.key?('data-ruled-line') })
    expect(rows.map { |row| row['aria-hidden'] }).to all(eq('true'))
    expect(rows.map { |row| row.at_css('td')['colspan'] }).to all(eq('5'))
    expect(rows.map { |row| row.css('td').size }).to all(eq(1))
  end

  it 'renders nothing when nothing is missing' do
    expect(render_rows(missing: 0, colspan: 4).css('tr')).to be_empty
  end

  it 'renders nothing for a page that overflows its size' do
    expect(render_rows(missing: -2, colspan: 4).css('tr')).to be_empty
  end
end
