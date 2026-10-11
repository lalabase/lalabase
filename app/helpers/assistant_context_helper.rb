# frozen_string_literal: true

# The ONE place that decides how a page NAMES the object it is showing, so the
# assistant panel can offer to take it over without anybody clicking
# (Bezugs-Sammlung §8.3, formerly S4 T2 step 5b).
#
# A helper and not a literal in the view, because #ticket_display_frame has more
# than one root. The normal render puts _ticket_display there; a generated
# summary puts _ticket_content_for_frame there instead
# (TicketsController#render_summary_success), which is the same frame with a
# different wrapper. The first version wrote the marker by hand into
# _ticket_display alone, and after a summary the page silently stopped naming
# its object for the rest of its life -- the offer died while the user was still
# standing on the ticket, and nothing went red.
#
# Nesting the two is fine: a normal display carries the outer marker and the
# inner one, both naming the same ticket. What must not happen is a root that
# carries none.
module AssistantContextHelper
  # Answers the attribute triple, or nothing where there is no companion lane to
  # read it: the same gate the button in the object's header uses, so a page
  # without a panel carries no dead weight in every render.
  #
  # The TYPE travels with the id since S1: the panel composes the composite key
  # ("Ticket:<uuid>", §7.1) from the two. Both the type and the label come from
  # the registry, so a page cannot name an object the collection does not know --
  # an unregistered type answers nothing at all, fail-closed like everywhere else.
  #
  # The label is bounded by the reference chip's OWN constant, so the offer
  # cannot promise a text the chip then delivers differently.
  #
  # `suffix:` is a page's own word after the title, inside the same bound
  # (review of #799): the preview of an OLDER document version names the
  # document, and the offer built from this label would otherwise promise
  # answers about what is on screen while the tool reads the current version.
  # The suffix is what the offer strip and the draft pill say; the saved chip
  # renders the registry's title, and the help carries the rule.
  def assistant_context_attributes(record, suffix: nil)
    return unless record && assistant_available?

    entry = Assistant::ReferenceRegistry.entry_for(record.class.name)
    return if entry.nil?

    max = Neo::Chat::ReferenceChipComponent::MAX_TITLE_CHARS
    label = if suffix.present?
              "#{entry.title.call(record, max - suffix.length - 1)} #{suffix}"
            else
              entry.title.call(record, max)
            end

    tag.attributes(
      'data-assistant-context': record.id,
      'data-assistant-context-type': entry.type,
      'data-assistant-context-label': label
    )
  end

  # The OTHER seam by which a page hands its object to the panel: the attributes
  # of the button that SETS the reference on click (assistant-trigger, the
  # window-event seam). Same gate, same registry, same type spelling as the
  # marker above, in one place -- the ticket's action bar and the knowledge
  # lane's head both render this button, and two hand-written copies of four
  # attributes are two chances for the type and the marker to drift apart
  # (doc/assistent_wissen_kontext_plan.md, step 3).
  #
  # The caller owns the button element, its classes and its title: what a
  # button looks like belongs to its row, what it SAYS to the panel belongs here.
  def assistant_trigger_attributes(record)
    data = assistant_trigger_data(record)
    tag.attributes(data: data) if data
  end

  def assistant_trigger_data(record, intent: nil)
    return unless record && assistant_available?

    entry = Assistant::ReferenceRegistry.entry_for(record.class.name)
    return if entry.nil?

    data = {
      controller: 'assistant-trigger',
      assistant_trigger_type_value: entry.type,
      assistant_trigger_id_value: record.id,
      action: 'click->assistant-trigger#adopt'
    }
    data[:assistant_trigger_intent_value] = intent.to_s if intent.present?
    data
  end
end
