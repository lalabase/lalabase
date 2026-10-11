# frozen_string_literal: true

# The verbs of the AI protocol (doc/ki_bereich_navigation_plan.md L13/E5, slice S5).
#
# ONE owner for a list that is written in two places and, since S5, read in a third.
# Before there was a reader the verbs could live next to their writers as literals —
# Organisations::AiSettingsController::ACTIVITY_ACTIVATED / _DEACTIVATED for the opt-in
# switch, two strings inside Actors::SelectAiPackage#log_choice for the package axis.
# A reader changes that: a verb the display page does not know is not a rendering
# defect, it is a row that never appears in a trail whose whole purpose is that it has
# no holes. And nothing about the page would look broken — the missing row is invisible
# by definition.
#
# The two write sites still carry their own literals; they are in another slice's hands
# while S4/S5/S6 run in parallel and were deliberately left untouched here. What keeps
# the three in step is not a comment but spec/locales/ai_protocol_verbs_guard_spec.rb,
# which compares this list against the `activities.organisation.ai_*` keys — the display
# texts every write site has to add anyway, in both locales.
#
# ⚠️ S7 brings the fifth verb (the BYOK form, the third write site L13 still misses).
# It has to land HERE as well as at its write site, otherwise the protocol page keeps
# quiet about the one change that swaps the processor.
module AiProtocolActions
  # The organisation's legal-basis decision: the customer switching AI on or off.
  ACTIVATED = 'ai_activated'
  DEACTIVATED = 'ai_deactivated'

  # The decision about processors: which package, and which rung inside it. Two verbs
  # for two axes, because only one of them carries legal weight (P4e).
  PACKAGE_SELECTED = 'ai_package_selected'
  TIER_SELECTED = 'ai_tier_selected'

  # The BYOK form (S7). Its own verb next to the switch and the package choice: changing
  # provider, endpoint or token swaps the PROCESSOR, which is neither the legal-basis
  # decision nor a pick from the curated catalogue.
  CONFIGURATION_CHANGED = 'ai_configuration_changed'

  ALL = [ACTIVATED, DEACTIVATED, PACKAGE_SELECTED, TIER_SELECTED, CONFIGURATION_CHANGED].freeze
end
