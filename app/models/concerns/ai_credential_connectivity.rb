# frozen_string_literal: true

# Shared connection probe for the two classes mapping to the ai_credentials
# table: AiCredential (runtime) and Admin::AiCredential (the admin backend,
# which is where the "test connection" button actually lives). Same reason as
# AiCredentialPricing / AiCredentialCacheable: one implementation, so the two
# models cannot drift.
#
# What this replaces: both models carried their own #test_connection, and each
# was honest for exactly ONE provider — the runtime model made a real API call
# for 'openai', the admin model minted a real OAuth token for 'google', and
# both fell through to `access_token.present?` for everything else. For
# anthropic and openai_compatible the button therefore reported success as soon
# as the token field contained any text at all. That matters more after the EU
# presets (Mistral/IONOS/OVHcloud all route through openai_compatible): the one
# self-test an operator has before going live was a blind spot exactly where
# the endpoint is custom and most likely to be misconfigured.
#
# The stub sat on TWO levels, and both had to go: the models' fall-through
# (here) and AnthropicProvider#connectivity_check, which was itself
# `api_key.present?`. Routing anthropic through the provider alone would have
# moved the blind spot one layer down, not closed it — so that provider gained
# a real GET /v1/models probe in the same change.
#
# Now both route through Provider#connectivity_check — the same probe
# Organisations::AiSettingsController already used for the org-side button, so
# admin and org settings finally answer the same question the same way.
#
# NO ai_enabled / quota gate here, deliberately — same reasoning as
# VertexAvailabilityProbe: connectivity_check spends no tokens, carries no
# tenant content and has no organisation. It is an operator diagnostic on a
# SYSTEM credential, not inference on someone's data.
module AiCredentialConnectivity
  extend ActiveSupport::Concern

  # @return [Boolean] true when the credential round-trips to its provider.
  def test_connection
    return false unless enabled?

    probe_provider&.connectivity_check || false
  rescue StandardError => e
    # Diagnostic button: a broken credential must render a red flash, never a
    # 500. Breadth is intentional (providers wrap transport errors, but a
    # malformed service-account JSON can still surface as a raw parser error).
    Rails.logger.error(
      "AI credential connection test failed for #{name} (#{provider}): #{e.class}: #{e.message}"
    )
    false
  end

  private

  # nil when the provider is not Factory-buildable (legacy rows such as the
  # removed 'cohere') or the credential carries no secret — both mean "cannot
  # probe", which #test_connection reports as a failed test.
  def probe_provider
    klass = Lalabase::Llm::Factory::PROVIDER_CLASSES[provider]
    return nil if klass.nil?

    secret = probe_access_token
    return nil if secret.blank?

    klass.new(
      api_key: secret,
      organisation_id_param: organization_id.presence,
      # Same resolution the routing uses (#effective_api_base: dedicated column,
      # then the legacy additional_config['uri_base']) — probing a different
      # endpoint than the one chat will use would make a green test meaningless.
      # The FIFTH site of that rule, and the reason it now lives on the record:
      # as a Factory helper it was only reachable from here by naming the service,
      # and the rescue below turns any slip into a quiet `false` rather than a raise.
      uri_base: effective_api_base,
      additional_config: additional_config
    )
  end

  # The DECRYPTED token. Both including models (AiCredential and
  # Admin::AiCredential) declare `encrypts :access_token` on the shared table,
  # so the plain attribute read decrypts on either write path — no override
  # needed since the admin model gained its own `encrypts` declaration.
  def probe_access_token
    access_token
  end
end
