# frozen_string_literal: true

# The AI overview's row list (doc/ki_uebersicht_zeilenliste_plan.md).
module AiOverviewHelper
  # A figure inside a value of the row list: JetBrains Mono in heading colour, so the
  # digits of five rows line up under each other and the eye finds them; the words
  # around a figure stay in body colour. Takes text that is already formatted
  # (number_with_delimiter, l(date)) — this helper only dresses it.
  def ai_overview_figure(text)
    tag.span(text, class: 'font-mono text-heading')
  end
end
