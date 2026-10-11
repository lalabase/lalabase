# frozen_string_literal: true

require 'rails_helper'

# The admin answer to "which AI does this org actually use". Every example here
# is about a case where the OLD answer (has_own_ai_credentials? → "System-
# Credentials") named something the routing does not use.
RSpec.describe Admin::AiRoutingSummary do
  # .reload, because the examples below edit the package/rung AFTER the org was
  # built with it: the in-memory association would still carry the pre-edit tier
  # and the summary would be read off a record the DB no longer holds.
  subject(:summary) { described_class.for(organisation.reload) }

  describe 'a curated package org' do
    let(:chat_credential) do
      create(:ai_credential, name: 'Mistral FR', display_name: 'Mistral (EU)',
                             provider: 'openai_compatible', api_base: 'https://api.mistral.ai/v1',
                             region: 'eu', default_model: 'mistral-large-3')
    end
    let(:package) do
      create(:ai_package, :with_tiers).tap do |pkg|
        pkg.tiers.find_by(key: 'fast').update!(chat_credential: chat_credential)
      end
    end
    let(:organisation) { create(:organisation, ai_package: package, ai_package_tier_key: 'fast') }

    it 'names the PACKAGE credential and its rung — not the provider system credential' do
      # The system credential the old answer would have named. It must not win:
      # a curated org routes through the credential its package names (P0).
      create(:ai_credential, :active, provider: 'openai', name: 'System OpenAI')

      expect(summary.source).to eq(:package)
      expect(summary.label).to eq('Mistral (EU)')
      expect(summary.model).to eq('mistral-large-3')
      expect(summary.package).to eq(package)
      expect(summary.tier.key).to eq('fast')
      expect(summary.broken).to be(false)
    end

    it 'follows the rung the ORG picked, model included' do
      package.tiers.find_by(key: 'thorough').update!(chat_model: 'mistral-medium-3.5')
      organisation.update!(ai_package_tier_key: 'thorough')

      expect(summary.tier.key).to eq('thorough')
      expect(summary.model).to eq('mistral-medium-3.5')
    end

    # Regression: Admin::Organisation had no ai_package association, so
    # Factory#curated_package (organisation.try(:ai_package)) answered nil for
    # EVERY org on the admin side — the index would have shown a curated org as
    # running on the system credential.
    it 'resolves the package for the ADMIN model too, not only for ::Organisation' do
      admin_org = Admin::Organisation.find(organisation.id)

      expect(described_class.for(admin_org).source).to eq(:package)
      expect(described_class.for(admin_org).label).to eq('Mistral (EU)')
    end

    it 'flags a rung credential that cannot serve chat' do
      organisation # build the package while the credential is still assignable
      # update_columns: the model refuses to REFERENCE a disabled credential, so
      # this is the only way to reach the state an operator produces by
      # disabling a credential a package already points at.
      chat_credential.update_columns(enabled: false)

      expect(summary.source).to eq(:package)
      expect(summary.broken).to be(true)
    end
  end

  describe 'an org with its own token (BYOK)' do
    let(:organisation) do
      create(:organisation, ai_provider: 'anthropic', ai_access_token: "sk-ant-#{'x' * 40}",
                            preferred_chat_model: 'claude-sonnet-5')
    end

    it 'names the org provider and its chosen model' do
      expect(summary.source).to eq(:byok)
      expect(summary.label).to eq(AiCredential.provider_display_names['anthropic'])
      expect(summary.model).to eq('claude-sonnet-5')
      expect(summary.broken).to be(false)
    end

    # BYOK is TERMINAL, like Factory#resolve_credentials: an active system
    # credential for the same provider must not displace the org's own token.
    it 'does not fall back to the system credential of the same provider' do
      create(:ai_credential, :active, :chat_only, provider: 'anthropic', name: 'System Anthropic',
                                                  access_token: "sk-ant-#{'y' * 95}")

      expect(summary.source).to eq(:byok)
    end

    # Without a model of its own the provider decides — the view says so rather
    # than leaving the line blank.
    it 'leaves the model empty when the org pinned none' do
      organisation.update!(preferred_chat_model: nil)

      expect(summary.model).to be_nil
    end
  end

  describe 'an org on the system credential' do
    let(:organisation) { create(:organisation, ai_provider: 'openai') }

    it 'names the ACTIVE credential of the org provider and its default model' do
      create(:ai_credential, provider: 'openai', name: 'Alt OpenAI', active: false)
      active = create(:ai_credential, :active, provider: 'openai', name: 'System OpenAI',
                                               default_model: 'gpt-5')

      expect(summary.source).to eq(:system)
      expect(summary.label).to eq(active.display_label)
      expect(summary.model).to eq('gpt-5')
      expect(summary.broken).to be(false)
    end

    it 'flags an active credential whose purpose does not cover chat' do
      create(:ai_credential, :active, :embedding_only, provider: 'openai', name: 'Nur Embeddings')

      expect(summary.source).to eq(:system)
      expect(summary.broken).to be(true)
    end

    it 'reports :none when the provider has no active credential at all' do
      expect(summary.source).to eq(:none)
      expect(summary.label).to be_nil
      expect(summary.broken).to be(true)
    end
  end

  # Gate-free: the operator opens this page precisely to check the setup of an
  # org that is not calling anything yet.
  it 'answers for an org with the AI opt-in switched off' do
    create(:ai_credential, :active, provider: 'openai', name: 'System OpenAI')
    organisation = create(:organisation, ai_enabled: false)

    expect(described_class.for(organisation).source).to eq(:system)
  end
end
