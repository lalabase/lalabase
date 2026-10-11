# frozen_string_literal: true

# The single source of truth for a widget's header line, shared by every overview
# (Overview::*) and project-dashboard (Dashboard::*) widget. Before this, the header
# had drifted into several treatments — a muted "//" mono eyebrow, a bold inline
# title, a boxed header bar, and the dashboard's loud text-xl font-black — so the
# same conceptual element looked different on every card. Routing them all through
# one component makes the header impossible to diverge again.
#
# Style intent: keep the editorial mono-uppercase motif (it is the house label
# language) but raise the title to INK (text-cream-900) — one clear step darker
# than the cream-600 sub-labels that sit INSIDE a widget — so the title reads as
# the card's anchor, not as just another label. The leading "//" becomes a cobalt
# accent marker (an active brand tick), not greyed-out code.
#
#   render WidgetHeaderComponent.new(title: t('...'))                  # plain
#   render WidgetHeaderComponent.new(title: t('...'), subtitle: '…')   # + subtitle
#   render WidgetHeaderComponent.new(title: t('...')) do |header|      # + actions
#     header.with_actions { … buttons … }
#   end
class WidgetHeaderComponent < ViewComponent::Base
  # Optional right-aligned slot for action controls (view-all link, "+" button,
  # count badge, in-widget search trigger …). Dashboard widgets fill it; most
  # overview widgets leave it empty.
  renders_one :actions

  def initialize(title:, subtitle: nil)
    @title = title
    @subtitle = subtitle
  end

  private

  attr_reader :title, :subtitle
end
