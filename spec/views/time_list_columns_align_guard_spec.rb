# frozen_string_literal: true

require 'rails_helper'

# What: the month header and the row of the time list carry the same columns, in
#       the same order, at the same widths.
# Type: Static guard over the two partials.
# Why:  They are two files drawing one grid, and each time the grid changed this
#       branch I had to edit both by hand. Three times running I got it wrong in
#       one of them, and the third time the user saw it: the month sum sat 30px
#       left of the durations under it and the month name 44px left of the
#       titles, so a header that means "the total of this column" did not stand
#       over that column. Nothing failed, it just read as restless.
#
#       This is the cheap half of the fix. The expensive half would be one owner
#       for the widths; until that exists, this makes the divergence loud.
RSpec.describe 'Time list column skeleton', type: :view do
  # A column is an element that is BOTH fixed-width and non-shrinking. The
  # lookbehind keeps "min-w-0" out: it ends in w-0 and is not a column.
  def columns_of(partial)
    path = Rails.root.join('app/views/organisations/time_sessions', partial)
    path.read.scan(/class="([^"]*\bshrink-0\b[^"]*)"/).flatten.filter_map do |classes|
      classes[/(?<![-\w])w-\S+/]
    end
  end

  let(:row) { columns_of('_aggregate_row.html.erb') }
  let(:header) { columns_of('_month_group.html.erb') }

  it 'draws the same columns in the same order in both files' do
    expect(header).to eq(row)
  end

  # The other axis. Measured in a browser on 30.08.2026, the eight columns of a
  # row had eight different vertical centres, spread over 9px, and the six of a
  # booking over 8.6px. Every one of them was defensible on its own: a pt-1 to
  # drop a checkbox, a pt-px to nudge a number, an h-5 for the mark, a baseline
  # for the text. Together they read as restlessness, and the user saw it before
  # anyone measured it. One 24px box now, either as h-6 + items-center or as
  # leading-6, and whatever can wrap grows downward out of it.
  #
  # Scans the class ATTRIBUTES only: the comments above name these very classes
  # to explain why they are gone, and a guard that reads its own rationale as a
  # violation teaches people to delete the rationale.
  describe 'the vertical line box' do
    let(:nudges) { %w[pt-px pt-1 items-baseline leading-snug leading-relaxed h-5] }

    def class_attributes(partial)
      source = Rails.root.join('app/views/organisations/time_sessions', partial).read
      # Both spellings of a class attribute: the literal HTML one and the Ruby
      # kwarg on link_to/components. A nudge smuggled in through `class:` must
      # fail the guard exactly like one in markup.
      source.scan(/class="([^"]*)"/).flatten +
        source.scan(/class: *['"]([^'"]*)['"]/).flatten
    end

    # The phone joined on 30.08.2026, when it stopped drawing its own structure.
    # It has different COLUMNS (a phone is not a table) but the same line box.
    %w[
      _aggregate_row.html.erb _session_line.html.erb
      _mobile_ticket_group.html.erb _mobile_session_card.html.erb
    ].each do |partial|
      it "keeps #{partial} free of per-column vertical nudges" do
        found = class_attributes(partial).flat_map(&:split).uniq & nudges

        expect(found).to be_empty
      end

      it "gives #{partial} the shared box" do
        classes = class_attributes(partial).flat_map(&:split)

        expect(classes).to include('h-6').or include('leading-6')
      end
    end
  end

  # Pinned so a green comparison of two empty lists can never pass for agreement.
  it 'finds the columns at all' do
    expect(row.size).to be >= 8
    expect(row.first).to eq('w-4')
    expect(row.last).to eq('w-6')
  end
end
