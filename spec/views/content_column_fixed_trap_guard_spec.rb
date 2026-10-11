# frozen_string_literal: true

require 'rails_helper'

# Guard: the master-detail content column must not retain a lingering transform.
#
# Regression guard for "the move-ticket modal is unusable in the ticket detail
# view" (backdrop lays over the whole pane, modal cannot be operated).
#
# Root cause: `.layout:not(.hide-content) .content` plays an entrance animation
# (`fadeSlideInRight`) whose end keyframe is `transform: translateX(0)`. With
# `animation-fill-mode: both` (or `forwards`) the column KEEPS that transform
# after the animation ends. Any non-none transform makes .content the
# containing block for `position: fixed` descendants AND opens a new stacking
# context — which trapped the move-ticket modal (rendered inline inside
# #ticket-header in this column) inside the scrollable pane instead of the
# viewport, so its backdrop/card were clipped and unclickable.
#
# The fix omits the forwards fill so the transform clears after the animation
# (base `transform: none`) and fixed descendants anchor to the viewport again.
# This guard fails if a forwards/both fill is reintroduced on the content
# column's entrance animation. If you ever need a held end-state here, make the
# keyframe end on `transform: none` instead — never leave a lingering transform
# on a column that hosts fixed-positioned modals.
RSpec.describe 'Content column fixed-positioning trap guard' do
  def layout_css_path
    Rails.root.join('app/assets/stylesheets/layout.css')
  end

  # Declaration body of the content-column entrance-animation rule, or nil.
  def content_column_rule_body
    css = File.read(layout_css_path)
    match = css.match(/\.layout:not\(\.hide-content\)\s+\.content\s*\{([^}]*)\}/m)
    match && match[1]
  end

  it 'still finds the content-column entrance rule (selector not renamed away)' do
    expect(content_column_rule_body).to be_present, <<~MSG
      Could not find the `.layout:not(.hide-content) .content` rule in
      layout.css. If the selector was renamed, point this guard at the new one
      so the fixed-positioning trap stays covered.
    MSG
  end

  it 'does not keep a lingering transform via a forwards/both animation fill' do
    body = content_column_rule_body
    skip 'content-column rule not found' if body.nil?

    animation = body[/animation\s*:\s*([^;]*);/, 1].to_s
    expect(animation).to be_present,
                         'Expected an `animation` declaration on the content column.'

    expect(animation).not_to match(/\b(both|forwards)\b/), <<~MSG
      The master-detail content column keeps a lingering transform.

        animation: #{animation.strip};

      A forwards/both fill-mode holds the entrance animation's end keyframe,
      which sets `transform: translateX(0)`. That non-none transform makes
      `.content` the containing block for position:fixed descendants and a new
      stacking context — trapping the inline move-ticket modal inside the detail
      pane (backdrop/card clipped and unclickable).

      Drop the forwards/both fill so the transform clears after the animation,
      or end the referenced keyframe on `transform: none`.
    MSG
  end
end
