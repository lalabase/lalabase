# frozen_string_literal: true

# app/services/actors/remove_ai_configuration.rb
#
# "Zugang entfernen" — the companion Actors::SaveAiConfiguration deliberately refuses to
# be (doc/ki_bereich_navigation_plan.md, decision E2 Weg A, sharpened by E2a).
#
# E2 chose to KEEP a stored key when the organisation moves to a package or a system
# credential, because the old #update dropped it on every switch and a key most providers
# never show again was gone with one careless click (L3). The price of that choice is
# this class. Two consequences make it a precondition of the rewiring rather than a nice
# extra:
#
#   * Factory#resolve_credentials takes the BYOK branch for as long as a token is stored,
#     and Organisation#has_valid_ai_configuration? never falls back to the system
#     credential once one is present. `ai_access_token: nil` in the old #update was the
#     ONLY existing way back to the system credential for an organisation without a
#     package. Rewiring the save onto an actor that never clears, without building this,
#     would have taken that way back away.
#   * The DSGVO argument the E2 table raises against Weg A — "an unused key lies around
#     encrypted" — is answered by an explicit action or it is not answered at all.
#
# What it does NOT do is refuse. Every other write in this area can be turned away
# (incomplete, unusable key, unsafe endpoint, re-entry required); this one is the escape
# hatch those refusals are measured against, and an escape hatch with conditions is a
# trap. It also clears the connection verdict: ai_connection_status describes an access
# that no longer exists, and leaving "ok" behind would let the hub card vouch for
# something that is gone.
module Actors
  class RemoveAiConfiguration < BaseActor
    # ai_provider is deliberately NOT cleared. It is not part of the secret — it is the
    # organisation's answer to "which system credential should serve us", and that answer
    # survives handing back the key. Clearing it would silently move an organisation that
    # ran on Anthropic onto the openai default (Factory#chat_provider_name's fallback),
    # i.e. change the processor as a side effect of removing a key. Nothing on the screen
    # would say so.
    CLEARED = (AiConfigurationAudit::COLUMNS - %i[ai_provider]).freeze

    def initialize(organisation:, current_user:)
      super()
      @organisation = organisation
      @current_user = current_user
    end

    def record
      @organisation
    end

    def perform
      # Same lock and the same reason as Actors::SaveAiConfiguration#perform: the audit
      # row's "from" side is a comparison against a stored state, and that comparison is
      # a lie if the row has moved under this request. lock! reloads, so it runs before
      # anything is read.
      @organisation.lock!

      previous = AiConfigurationAudit.snapshot(@organisation)
      @organisation.assign_attributes(CLEARED.index_with(nil))
      # Not part of the audited columns, so it is cleared next to them rather than
      # through them: the verdict is ABOUT the access, not part of it.
      @organisation.assign_attributes(ai_connection_status: nil, ai_connection_checked_at: nil)
      @organisation.save!

      AiConfigurationAudit.call(organisation: @organisation, current_user: @current_user,
                                before: previous, after: AiConfigurationAudit.snapshot(@organisation))
    end
  end
end
