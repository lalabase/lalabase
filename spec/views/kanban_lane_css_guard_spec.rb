# frozen_string_literal: true

require 'rails_helper'

# Guard: the board's lane in the stylesheet (doc/kanban_ticket_als_bahn_plan.md,
# S1a, S2, S4, S6). A reading of layout.css, not of the cascade: it proves
# that the rules exist, in the block they belong to; that they WIN at the
# boundaries (759/760/761, 899/900/901, 1023/1024/1025) only a browser can
# prove, and that is the owner's own check.
RSpec.describe 'Kanban lane stylesheet guard' do
  let(:css) { File.read(Rails.root.join('app/assets/stylesheets/layout.css')) }

  # The switch stands in both views at every state (user, 09.09.2026): no rule
  # hides it behind an open lane any more, on the table or on the board.
  it 'never hides the view switch behind an open lane' do
    expect(css).to include('[data-page-view-switch] {')
    expect(css).not_to match(/show-content[^{]*\[data-page-view-switch\]/)
  end

  it 'has no slide-over rule left' do
    expect(css).not_to include('.kanban-slide-over')
  end

  it 'keeps the board out of the grid system nowhere' do
    expect(css).not_to include(':not(.kanban-layout)')
  end

  it 'gives the 900px block the lane variant and hides the handle while the list track is 0 (S6)' do
    block = css[/@media \(max-width: 900px\) \{.*?\n\}\n/m]
    expect(block).to include('.layout--lane.two-column.hide-panel:not(.hide-content):not(.hide-list) {')
    expect(block).to include('.lane-split')
    focus = css[/@media \(min-width: 1024px\) \{.*?\n\}\n/m]
    expect(focus).to include('body.assistant-panel-open .layout.two-column:not(.hide-content) .lane-split')
  end

  it 'narrows the columns while the lane is open through the board variables, one owner of both widths (S2)' do
    expect(css).to include('.layout.show-content .kanban-board {')
    expect(css).to match(/\.kanban-column \{[^}]*var\(--kanban-column-min\)/m)
    expect(css).to match(/\.kanban-board \{[^}]*--kanban-column-basis: 300px/m)
  end

  # The 24px channel belongs to the open lane (user, 09.09.2026): next to a
  # 0px track it was 24px of nothing between the list and the page inset. Shut,
  # the gap is 0 and animates with the tracks; with a 0px LIST track (900px,
  # the assistant focus mode, hide-list) the same, or the lane starts 24px in.
  it 'closes the channel wherever a track is 0, and animates it with the tracks' do
    shut = css[/\.layout--lane\.two-column\.hide-panel\.hide-content:not\(\.hide-list\) \{[^}]*\}/m]
    expect(shut).to include('column-gap: 0')
    expect(css).to match(/\.layout\.two-column \{[^}]*transition:[^;]*column-gap 0\.25s/m)
    narrow = css[/@media \(max-width: 900px\) \{.*?\n\}\n/m]
    expect(narrow).to match(/\.layout--lane\.two-column\.hide-panel:not\(\.hide-content\):not\(\.hide-list\) \{[^}]*column-gap: 0/m)
    focus = css[/@media \(min-width: 1024px\) \{.*?\n\}\n/m]
    expect(focus).to match(/body\.assistant-panel-open \.layout\.two-column:not\(\.hide-content\)\.hide-panel \{[^}]*column-gap: 0/m)
    docked = css[/\.layout--lane\.two-column\.hide-panel\.hide-content:not\(\.hide-list\)\.column-picker-open \{[^}]*\}/m]
    expect(docked).to include('column-gap: 24px')
  end

  it 'tones the chosen card with the row token (rule 2)' do
    expect(css).to match(/\.kanban-card\.selected-row \{[^}]*var\(--selected-row\)/m)
  end

  # The keyboard's four forms (doc/kanban_keyboard_plan.md, S1 and S6): focus
  # is a ring outside the stop and never a fill or a box-shadow ring; the
  # open card's edge is the muted token; carried, left behind and target
  # have rules of their own; reduced motion takes the lift off the carried
  # card. A reading of the stylesheet; that the ring is not clipped by the
  # column scroller only a browser proves (the 8px padding is the answer).
  it 'draws the focus as an outline outside every stop, one rule for card, head and + Ticket' do
    rule = css[/\.kanban-card:focus-visible,\n\.kanban-column-header:focus-visible,\n\.kanban-add-ticket:focus-visible \{([^}]*)\}/m, 1]
    expect(rule).to be_present
    expect(rule).to include('outline: 2px solid rgb(var(--ink))')
    expect(rule).to include('outline-offset: 3px')
    expect(rule).not_to include('box-shadow')
    expect(rule).not_to include('background')
    expect(css).not_to match(/\.kanban-add-ticket:focus-visible \{[^}]*box-shadow/m)
    expect(css).to match(/\.kanban-scroll \{[^}]*padding: 14px 8px 12px/m)
  end

  it 'gives the open card the muted edge and the carried card, its picture and its target their forms' do
    expect(css).to match(/\.kanban-card\.selected-row \{[^}]*border-color: rgb\(var\(--cream-600\)\)/m)
    expect(css).to match(/\.kanban-card\.kanban-carried \{[^}]*transform: translate\(-2px, -3px\)/m)
    expect(css).to match(/\.kanban-card\.kanban-ghost,\n\.kanban-card\.kanban-placeholder \{[^}]*opacity: 0\.55/m)
    # The whole column is the target, never the card list (the cards covered the ring there).
    expect(css).to match(/\.kanban-column:has\(\.kanban-ghost\),\n\.kanban-column\.kanban-target \{[^}]*var\(--kanban-target\)/m)
    expect(css).not_to include('.kanban-card-list.kanban-target')
    expect(css).to match(/\.kanban-column \{[^}]*align-self: flex-start/m)
    expect(css).to match(/\.kanban-board \{[^}]*--kanban-target: 245 158 11/m)
    expect(css).to match(/\.dark \.kanban-board \{[^}]*--kanban-target:/m)
    reduced = css[/@media \(prefers-reduced-motion: reduce\) \{\n  \.kanban-card,[^}]*\}/m]
    expect(reduced).to include('.kanban-card.kanban-carried')
    expect(reduced).to include('transform: none')
  end
end
