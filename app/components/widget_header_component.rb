# frozen_string_literal: true

# The single source of truth for a widget's header line, shared by every overview
# (Overview::*) and project-dashboard (Dashboard::*) widget. Before this, the header
# had drifted into several treatments (a muted mono eyebrow, a bold inline title,
# a boxed header bar, and the dashboard's loud text-xl font-black), so the same
# conceptual element looked different on every card. Routing them all through
# one component makes the header impossible to diverge again.
#
# Style intent: the title wears the section label of the app (mono, 11px,
# semibold, uppercase, tracking 0.14em), the same shape as "PROJEKTE" in the
# sidebar and the summary heading of the ticket timeline. It is INK
# (text-cream-900), one clear step darker than the cream-600 sub-labels that sit
# INSIDE a widget, so it reads as the card's anchor. Nothing stands in front of
# it: the "//" marker was a leftover of an older design and was removed.
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
