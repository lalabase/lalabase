# frozen_string_literal: true

require 'ipaddr'

# app/services/actors/save_ai_configuration.rb
#
# The write behind "Eigene Konfiguration" — an organisation's OWN AI access
# (doc/ki_bereich_navigation_plan.md S7, decision E6-A).
#
# Why an actor and not the inline update it replaces: the old
# AiSettingsController#update was a bare `@organisation.update(...)` that wrote
# four columns, deleted a key as a side effect, and left no trace. Three of the
# thirteen gaps in §4 of the plan live in exactly that method (L3, L7, L9), and
# it is the THIRD and last write site of the AI protocol (E5/L13) — the two others
# already write their audit row through a command object.
#
# ⚠️ This actor is the FIRST org-side write path for `ai_api_base` (L7: both it and
# `preferred_chat_model` had zero hits in app/views and app/controllers on
# 2026-08-05). Making the endpoint settable is the whole point of S7, and it is
# also what turns E2's "never drop the stored key" into an exfiltration primitive
# if left unguarded: keep the key, repoint the endpoint, and the next chat call
# hands the decrypted BYOK token to whoever owns that URL — a key the UI only ever
# shows masked (Organisation#masked_ai_token). #reject_token_reentry! and
# #reject_unsafe_api_base! are the two halves that close it, and they are the
# reason this actor refuses writes the old #update happily accepted.

module Actors
  class SaveAiConfiguration < BaseActor
    ERROR_SCOPE = 'services.actors.save_ai_configuration'

    # The verb this write files under. Its own, next to ai_activated and
    # ai_package_selected: switching the provider or the token of an organisation's
    # own access is a decision about the PROCESSOR, distinct from the legal-basis
    # decision (the on/off switch) and from picking a curated package.
    # Reads the list rather than holding a literal. The list PREDICTED this: "S7 brings
    # the fifth verb ... It has to land HERE as well as at its write site, otherwise the
    # protocol page keeps quiet about the one change that swaps the processor." It did
    # not, and nothing went red — AiProtocolsController filters on ALL, the guard compares
    # ALL against locale keys, and both were silent together. Every row this actor writes
    # would have been invisible on the page built to show it.
    #
    # Delegated since the removal half of S7 exists: the verb, the payload and the three
    # properties an Activity needs here now live with AiConfigurationAudit, so the two
    # halves of one decision cannot file under different names.
    ACTIVITY_ACTION = AiConfigurationAudit::ACTION

    # Which fields an own access needs, per provider — L7. Not decoration: an
    # organisation whose own access is incomplete is not "partly configured", it is
    # BROKEN, because BYOK is terminal (Organisation#has_valid_ai_configuration?
    # never falls back to the system credential once own credentials are present).
    # Saving an unusable combination therefore switches AI off in practice while the
    # form reports success — which is what this table exists to prevent.
    #
    # PRESENCE only. The shape of a key is a different question and belongs to its
    # owner: #reject_unusable_token! asks Organisation#own_ai_token_usable?, which
    # knows that `google` needs a service-account JSON and `openai` an sk-/org- key.
    # Answering that here would be a second copy of a rule that already exists.
    REQUIRED_FIELDS = {
      AiCredential::PROVIDER_OPENAI => %i[ai_access_token],
      AiCredential::PROVIDER_ANTHROPIC => %i[ai_access_token],
      AiCredential::PROVIDER_GOOGLE => %i[ai_access_token],
      AiCredential::PROVIDER_OPENAI_COMPATIBLE => %i[ai_access_token ai_api_base preferred_chat_model]
    }.freeze

    # The audit owns the list (AiConfigurationAudit::COLUMNS): what this actor may write
    # and what the protocol row describes are one question with one answer. A writable
    # column outside the audit is a change nobody can reconstruct afterwards.
    WRITABLE = AiConfigurationAudit::COLUMNS

    def initialize(organisation:, params:, current_user:)
      super()
      @organisation = organisation
      @params = params.to_h.symbolize_keys
      @current_user = current_user
    end

    def record
      @organisation
    end

    def perform
      # FIRST, and inside the actor's transaction. Everything below compares an
      # intended state against a stored one — the completeness check, the re-entry
      # rule, the audit row's "from" side — and all three are lies if the stored
      # side is a row somebody else has already moved. Same lock Actors::SelectAiPackage
      # takes for the same reason (its rationale is spelled out at
      # AiSettingsController#select_package): a pre-lock read speaks about a row this
      # request may no longer be writing. lock! reloads, so it must run before any
      # assignment.
      @organisation.lock!

      provider = @params[:ai_provider].to_s
      reject!(:unknown_provider) unless AiCredential::PROVIDERS.include?(provider)

      previous = current_values
      # Assigned, not merged into a parallel hash: every check below then asks the
      # RECORD, which is also what Organisation#own_ai_token_usable? reads. One
      # representation of "what is about to be stored" instead of two that can drift.
      @organisation.assign_attributes(writable_attributes)

      reject_invalid!(provider, previous)
      @organisation.save!

      log_change(previous)
    end

    private

    # Order is load-bearing, cheapest and most specific message first: "endpoint and
    # model are missing" is more useful than "the key does not fit", and both are more
    # useful than the re-entry demand, which is about a write the customer may not
    # realise they are making.
    def reject_invalid!(provider, previous)
      reject_incomplete!(provider)
      reject_unsafe_api_base!
      reject_token_reentry!(previous)
      reject_unusable_token!(provider)
    end

    def current_values
      AiConfigurationAudit.snapshot(@organisation)
    end

    # Three states, not two — this is where the L3 defect lived:
    #
    #   ABSENT  (no key in params)      → keep the stored value. A caller that says
    #                                     nothing about a column is not asking for it
    #                                     to be emptied, and a partial payload (API,
    #                                     a form that renders per provider) must not
    #                                     be destructive.
    #   BLANK   (key present, empty)    → clear it. That is how a customer removes an
    #                                     endpoint or an organisation id, and without
    #                                     it those columns would need their own action.
    #   PRESENT                         → write it.
    #
    # ai_access_token is the ONE exception: blank means "unchanged" there, because the
    # field is rendered empty on every visit (the secret is never echoed back), so a
    # blank submission is the normal case rather than a request to clear. That is E2
    # (Weg A) — the old #update wrote `ai_access_token: nil` on every switch to system
    # credentials, so one careless click cost a key most providers never show again,
    # with no warning and no undo (L3).
    #
    # Removing an access is therefore a SEPARATE, explicit action, not something a save
    # can do by omission: Actors::RemoveAiConfiguration, the companion E2-A asks for. It
    # is not optional decoration — Factory#resolve_credentials takes the BYOK branch for
    # as long as a token is stored, so without it an organisation without a package would
    # have no way back to the system credential at all.
    def writable_attributes
      WRITABLE.each_with_object({}) do |field, attrs|
        next unless @params.key?(field)
        next if field == :ai_access_token && @params[field].blank?

        attrs[field] = @params[field].presence
      end
    end

    # Reads the RECORD, i.e. what is about to be stored — a form that leaves the token
    # blank is keeping the stored one, and that stored one satisfies the requirement.
    #
    # fetch WITHOUT a default, deliberately: a provider added to AiCredential::PROVIDERS
    # but not to the table above would otherwise get zero requirements and save an
    # unusable access in silence. Loud here beats plausible later; same choice
    # AiSettingsController::SEARCH_OUTCOMES makes for the same reason. Unreachable by a
    # request — #perform rejects anything outside PROVIDERS first — so the KeyError can
    # only ever be a developer's missing table row.
    def reject_incomplete!(provider)
      missing = REQUIRED_FIELDS.fetch(provider).select { |field| @organisation.public_send(field).blank? }
      return if missing.empty?

      reject!(:incomplete, fields: missing.map { |field| I18n.t("#{ERROR_SCOPE}.fields.#{field}") }.join(', '),
                           provider: provider_label(provider))
    end

    # The endpoint is a URL the customer types, and the app sends the organisation's
    # decrypted key to it as a bearer (OpenAiCompatibleProvider#client). Two properties
    # are therefore not cosmetic:
    #
    #   * https — over http the key is on the wire in clear.
    #   * a public host — without this the same field reaches the app server's own
    #     network (127.0.0.1, RFC1918, link-local), i.e. SSRF with a credential attached.
    #
    # Where a host leads is Lalabase::PublicAddress's question, asked here so a wrong
    # endpoint is refused while its owner is still on the form. It is not the
    # protection: DNS answers again for every request and can point inward by then, so
    # Lalabase::Llm::PublicEndpointAdapter asks again for every connection and sends the
    # socket to exactly the address it judged. The embedding lane (embedding_api_base)
    # has no org-side write path yet; when S5 adds one, it calls the same owner.
    def reject_unsafe_api_base!
      base = @organisation.ai_api_base
      return if base.blank?

      uri = parsed_api_base(base)
      reject!(:api_base_not_https) unless uri.is_a?(URI::HTTPS) && uri.hostname.present?
      reject!(:api_base_not_public) unless public_host?(uri.hostname)
    end

    def parsed_api_base(base)
      URI.parse(base)
    rescue URI::InvalidURIError
      nil
    end

    def public_host?(hostname)
      Lalabase::PublicAddress.public?(hostname)
    end

    # The other half of the exfiltration guard. Keeping a stored key (E2-A) is safe only
    # as long as the key keeps pointing where its owner pointed it. Moving the provider
    # or the endpoint underneath a key the current admin never saw is a way to READ that
    # key — the UI only ever renders it masked — so such a move has to be paid for by
    # typing the key in again.
    #
    # Not a validation of the key itself: supplying a new token satisfies this in every
    # case, including retyping the same one. It is a proof of possession, not a rotation.
    def reject_token_reentry!(previous)
      return if @params[:ai_access_token].present?
      return if previous['ai_access_token'].blank?
      return unless @organisation.ai_provider != previous['ai_provider'] ||
                    @organisation.ai_api_base != previous['ai_api_base']

      reject!(:token_reentry_required)
    end

    # Asks the ONE owner of "does this key shape fit this provider"
    # (Organisation#own_ai_token_usable?, public since S7 for exactly this call) BEFORE
    # the write, so the answer cannot become "not configured" only after a save that
    # reported success. Presence alone let `openai` store a garbage key and `google` a
    # non-JSON one, and BYOK is terminal, so both switched AI off in practice.
    def reject_unusable_token!(provider)
      return if @organisation.own_ai_token_usable?(provider)

      reject!(:unusable_token, provider: provider_label(provider))
    end

    # The third write site of the AI protocol (E5/L13). The row's shape, its verb and
    # the three properties it needs (both skip flags, with_tenant, only when something
    # moved) belong to AiConfigurationAudit since the removal half of S7 exists — see
    # there for why each of them was measured rather than assumed.
    #
    # NO rescue here, and that is a deliberate departure from AiSettingsController
    # #log_ai_switch, whose comment anticipates this move. There the switch had to stay
    # applied whatever happened to its audit row, because deactivate is the compliance
    # off-switch. A configuration change carries no such duty: it is a single write with
    # one meaning, so an unwritable audit row rolls the whole thing back rather than
    # leaving a changed recipient nobody can reconstruct. All-or-nothing is the safer
    # half of that trade HERE, and the opposite of the safer half THERE.
    def log_change(previous)
      AiConfigurationAudit.call(organisation: @organisation, current_user: @current_user,
                                before: previous, after: current_values)
    end

    def provider_label(provider)
      AiCredential.provider_display_names[provider] || provider
    end

    def reject!(code, **interpolations)
      raise ActorError.new(I18n.t("#{ERROR_SCOPE}.#{code}", **interpolations), code: code)
    end
  end
end
