# frozen_string_literal: true

# Turns a Lalabase::Llm::ConnectionCheck result into the one flash the admin reads
# (doc/ki_bereich_navigation_plan.md S7, decision E3).
#
# Two actions run the probe and they must not answer differently: the header button on
# "Zugang" (AiSettingsController#test_connection, which checks what is stored) and
# "Speichern und prüfen" on the own-configuration screen (AiConfigurationsController
# #update, which checks what was just saved — that is E3-A, and it is what closes L5).
# A wording that lived in one of the two would drift the first time a message was
# improved, and the drift would be invisible: both produce a flash and disappear.
#
# The four outcomes are kept apart on purpose. "Keine Modelle gefunden" and "kein
# Zugang hinterlegt" send the admin to two very different places, and folding either
# into the generic error text would cost exactly the information the button exists to
# give.
module AiConnectionCheckable
  extend ActiveSupport::Concern

  # Runs the probe, records its verdict (the service does that) and returns the flash
  # pair for a redirect_to.
  # @return [Hash] :notice or :alert, ready to splat into redirect_to
  def ai_connection_check_flash(organisation)
    result = ::Lalabase::Llm::ConnectionCheck.call(organisation: organisation)
    label = ::AiCredential.provider_display_names[result.provider_name] || result.provider_name

    case result.outcome
    when :ok then { notice: t('flash.ai_settings.connection_success', provider: label) }
    when :no_models then { alert: t('flash.ai_settings.connection_no_models') }
    when :missing_credential then { alert: t('flash.ai_settings.no_client', provider: label) }
    else
      # A fixed text, never the words of the failure. Those say whether a port is open
      # (refused, timed out, TLS failed), and with an endpoint the customer typed that
      # is a port scan of whatever the endpoint reaches. The reason is in the log
      # (Lalabase::Llm::ConnectionCheck writes it there).
      { alert: t('flash.ai_settings.connection_error') }
    end
  end
end
