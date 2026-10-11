# frozen_string_literal: true

# Attaching a persona, with the ONE rule that must hold wherever it happens: the
# chosen row belongs to this record's own organisation or to the global pool, and
# it is active.
#
# Two records carry a persona for two different lifetimes -- Chat pins one for a
# single thread, ChatStylePreference stores a person's standing choice -- but the
# rule about WHICH personas may be attached is the same rule, and it was written
# out by hand in Chat before this concern existed. A second hand-written copy is
# the documented signal to encapsulate: the check guards a prompt fragment that
# goes into the system prompt, so a place that forgets it is an injection path,
# not a cosmetic gap.
#
# Defense in depth on purpose. Every write path validates the id against the
# offered pool already; this holds when a console, an import or a controller
# written later writes around that door.
module PromptPersonaSelectable
  extend ActiveSupport::Concern

  included do
    belongs_to :prompt_persona, optional: true

    validate :prompt_persona_available
  end

  # The chosen persona while it is still IN EFFECT, else nil.
  #
  # NOT `prompt_persona` directly, for two things the stored column cannot know:
  #
  #   * the persona can be deactivated org-wide after somebody picked it, and the
  #     association would happily keep handing back a retired row,
  #   * an org can publish its OWN persona under the same key as a global one
  #     (organisations/prompt_personas#create, ?from=<key>), and from that moment
  #     the org row is the one in effect -- `pickable_for` collapses per key with
  #     the org row winning, `available_for` does not.
  #
  # So this asks `pickable_for`, the SAME expression the picker offers and the
  # write path accepts. Where the three drift, a surface shows one persona while
  # the system prompt gets another, and nothing says so.
  #
  # Deliberately NOT the pool the validation below uses. `available_for` is the
  # authorization boundary ("may this org ever hold this row"), and it has to stay
  # the wider one: a row whose persona got overridden must remain SAVEABLE, or
  # setting an unrelated style level would start raising. In effect vs. allowed to
  # be stored are two questions, and only the first one changes an answer.
  def resolved_persona
    return nil if prompt_persona_id.blank?

    PromptPersona.pickable_for(persona_pool_organisation).find { |persona| persona.id == prompt_persona_id }
  end

  private

  def prompt_persona_available
    return if prompt_persona_id.blank?
    return if PromptPersona.available_for(persona_pool_organisation).exists?(id: prompt_persona_id)

    errors.add(:prompt_persona, :unavailable)
  end

  # Resolved defensively: acts_as_tenant sets organisation_id from the current
  # tenant, but on a freshly built record (before that runs) it may still be nil,
  # so fall back to the ambient tenant.
  def persona_pool_organisation
    organisation || ActsAsTenant.current_tenant
  end
end
