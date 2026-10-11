# frozen_string_literal: true

# Shared cache invalidation for the two classes that map to the ai_credentials
# table: AiCredential (runtime, tenant-scoped seam) and Admin::AiCredential (admin
# backend, cross-tenant). AiCredential.active_for_provider caches the active
# credential per provider for 5 minutes; ANY write — including admin price/config
# edits and admin activation — must drop that key, otherwise a price change is
# ignored for up to 5 minutes.
#
# Previously only AiCredential cleared the cache, and only on active-flips, so
# admin edits (the actual editing surface) never invalidated it. Both facts are
# fixed here in ONE place so the two models cannot drift.
module AiCredentialCacheable
  extend ActiveSupport::Concern

  # Key must stay identical to AiCredential.active_for_provider's fetch key.
  def self.cache_key_for(provider)
    "active_ai_credential_#{provider}"
  end

  included do
    after_save :clear_active_provider_cache
    after_destroy :clear_active_provider_cache
  end

  private

  def clear_active_provider_cache
    Rails.cache.delete(AiCredentialCacheable.cache_key_for(provider))
  end
end
