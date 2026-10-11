# frozen_string_literal: true

# The inside of a change row's disclosure: one entry per changed field
# (Aktivitätenfeed, 10.09.2026). A short pair keeps the line's own arrow form;
# a long one reads "vorher" above "nachher", typeset and never struck through,
# because a struck-through paragraph cannot be read. The list of a bulk run (a
# TimelineHelper::Note) reads as its label above its text.
#
# Which form an entry takes is asked of the same rule that took the pair out
# of the line (TimelineHelper#timeline_change_inline?). The entries themselves
# come from TimelineHelper too; this component only renders them. It is shared
# by the single row and the collapsed run, in the ticket timeline and in the
# project feed - until 10.09.2026 each of those four disclosures carried its
# own copy of this markup.
class NeoActivityChangeDetailsComponent < ViewComponent::Base
  def initialize(changes:)
    super()
    @changes = changes
  end

  def render?
    changes.any?
  end

  private

  attr_reader :changes

  # A bulk run's list (TimelineHelper::Note) rather than a pair.
  def note?(entry)
    entry.is_a?(TimelineHelper::Note)
  end

  def inline?(change)
    helpers.timeline_change_inline?(change)
  end

  def markdown?(change, value)
    helpers.timeline_change_markdown?(change, value)
  end

  # The two sides of a long change, each with the word that says which one
  # it is.
  def sides(change)
    [[t('views.organisations.tickets.timeline.change_before'), change.before],
     [t('views.organisations.tickets.timeline.change_after'), change.after]]
  end
end
