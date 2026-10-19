# frozen_string_literal: true

# app/services/lalabase/llm/connection_check.rb
#
# "Does the access this organisation is configured with actually answer?" — the one
# question the AI area could ask but never remember (doc/ki_bereich_navigation_plan.md
# S7, decision E3, gaps L5/L6/L10).
#
# It exists as a service rather than as controller code because it now has TWO callers
# that must not disagree: the header button on "Zugang" and "Speichern und prüfen" on
# the own-configuration screen. Both have to run the same probe, judge it by the same
# rule and leave the same trace, and the version this replaces did none of that — it was
# eight lines of rescue chain inside Organisations::AiSettingsController, and its result
# lived exactly as long as one flash message.
#
# Three decisions carry the whole file:
#
#   * GATE-FREE (L6). Goes through Factory.chat_probe, not Factory.for_chat. The natural
#     order is "configure first, switch on afterwards", so the gated probe refused the
#     very organisation trying to set itself up, and an exhausted quota made it refuse
#     one whose access is perfectly fine. Neither answer is about the connection. The
#     rationale for why that is safe is stated once, at Factory#chat_probe.
#   * THE OUTCOME IS PERSISTED, THE PROVIDER'S WORDS ARE NOT (L10). Two columns,
#     ai_connection_checked_at and ai_connection_status, hold "when" and "ok/failed" —
#     never the message. A provider error can carry the endpoint, a request id, and on a
#     misconfigured openai_compatible endpoint whatever a stranger's server chose to
#     write; storing it would put unreviewed third-party text into a column the hub card
#     renders. The flash does not carry it either (AiConnectionCheckable): it would say
#     which ports an endpoint the customer typed can reach. The reason is in the log.
#   * A CHECK NEVER FAILS THE REQUEST. Every error becomes a result, because this is a
#     diagnostic: an admin pressing "prüfen" on a broken access must get a red answer,
#     not a 500.
module Lalabase
  module Llm
    class ConnectionCheck
      # The four answers, in the order they are decided. `:ok` is the only one that
      # stores AI_CONNECTION_OK — everything else is a failure of the access, including
      # :missing_credential, which is what an organisation on BYOK looks like the moment
      # its token is gone.
      #
      # :no_models is kept apart from :error although both are failures: it is the one
      # outcome where the request SUCCEEDED and the answer was empty, which points at a
      # key without model access rather than at a wrong key. Collapsing the two would
      # send the admin looking in the wrong place.
      OUTCOMES = %i[ok no_models missing_credential error].freeze

      Result = Struct.new(:outcome, :provider_name, :message, keyword_init: true) do
        def ok?
          outcome == :ok
        end
      end

      def self.call(**kwargs)
        new(**kwargs).call
      end

      def initialize(organisation:)
        @organisation = organisation
      end

      def call
        result = probe
        record(result.ok?)
        result
      end

      private

      def probe
        provider_name = ::Lalabase::Llm::Factory.chat_provider_name(@organisation)
        # connectivity_check returns false rather than raising when the request went
        # through and came back empty — that is :no_models, a different diagnosis from
        # a refused request.
        return Result.new(outcome: :ok, provider_name: provider_name) if
          ::Lalabase::Llm::Factory.chat_probe(@organisation).connectivity_check

        Result.new(outcome: :no_models, provider_name: provider_name)
      rescue ::Lalabase::Llm::Factory::MissingCredentialError => e
        Result.new(outcome: :missing_credential, provider_name: provider_name, message: e.message)
      rescue StandardError => e
        # Breadth on purpose, same as AiCredentialConnectivity: the providers wrap their
        # transport errors, but a malformed service-account JSON still surfaces as a raw
        # parser error, and a hand-typed endpoint can fail in ways no provider maps.
        Rails.logger.error("[ConnectionCheck] organisation #{@organisation.id}: #{e.class}: #{e.message}")
        Result.new(outcome: :error, provider_name: provider_name, message: e.message)
      end

      # update_columns, for the same reason Organisations::AiSettingsController#activate
      # gives: this write touches only its own two columns and must not be blocked by an
      # unrelated validation failure elsewhere on the organisation. A diagnostic that
      # cannot record its result because some other column is out of shape would be
      # worse than useless — it would report green while the hub stayed silent.
      #
      # No audit row, deliberately. The protocol (E5/L13) records DECISIONS a person
      # made about the processing; a connection probe changes nothing and would bury
      # those decisions under noise generated by a button anyone may press repeatedly.
      def record(successful)
        @organisation.update_columns(
          ai_connection_status: successful ? Organisation::AI_CONNECTION_OK : Organisation::AI_CONNECTION_FAILED,
          ai_connection_checked_at: Time.current,
          updated_at: Time.current
        )
      end
    end
  end
end
