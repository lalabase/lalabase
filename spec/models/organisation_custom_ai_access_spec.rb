# frozen_string_literal: true

# What: Organisation#ai_custom_access_configured? — "is there anything behind
#   'Eigene Konfiguration'?" (doc/ki_zugang_umbau_plan.md D7).
# Type: Model spec — one derived predicate, no persistence of its own.
# Why (philosophy): The schema knows two things and the customer sees three. A blank
#   ai_package_id means "own configuration" (convention E1-C) and says NOTHING about
#   whether credentials exist — which is how a fresh organisation came to read
#   "Eigene Konfiguration · Gewählt" without anyone having chosen anything. The third
#   state is derived here rather than added as a column, so this predicate is the whole
#   of the fix and has to be pinned per state.
# Contract: true exactly when the org has its own ai_access_token, for whichever
#   provider it routes to. See the provider-switch example below for the one thing the
#   expression looks like it does and does not.

require 'rails_helper'

RSpec.describe Organisation, '#ai_custom_access_configured?' do
  # A blank ai_package_id is deliberately NOT part of any example here. The predicate
  # answers "are credentials on record", the package id answers "which way is in force",
  # and folding the second into the first is exactly the conflation D7 exists to undo —
  # a caller that needs both asks both.
  it 'is false for a fresh organisation with no token at all' do
    organisation = create(:organisation, ai_access_token: nil, ai_provider: nil)

    expect(organisation.ai_custom_access_configured?).to be(false)
  end

  it 'is true once an own token is stored for the default provider' do
    organisation = create(:organisation, ai_provider: nil, ai_access_token: 'sk-live-key')

    expect(organisation.ai_custom_access_configured?).to be(true)
  end

  # The reason the predicate reads ai_provider instead of hardcoding OpenAI: an org on
  # Anthropic has its access set up just as much as an org on OpenAI, and a hardcoded
  # default would report the honest state for exactly one provider.
  it 'is true for a token stored against a non-default provider the org routes to' do
    organisation = create(:organisation, ai_provider: 'anthropic', ai_access_token: 'sk-ant-key')

    expect(organisation.ai_custom_access_configured?).to be(true)
  end

  # ⚠️ Measured, and it is NOT what the shape of the expression suggests. The predicate
  # passes the org's OWN ai_provider into has_own_ai_credentials?, whose provider check
  # is `ai_provider.blank? || ai_provider == provider` — asked about itself, that check
  # can never disagree. So the effective question is "is a token stored", and switching
  # the provider does not clear it.
  #
  # Pinned rather than fixed, and deliberately so: this is verbatim the expression the
  # view carried inline before D7 gave the rule one owner, and the rebuild's job was to
  # stop four copies drifting, not to change what any of them decided. Whether a
  # provider switch should invalidate the stored token is a real question — it belongs
  # to the setup screen that writes those columns, not to a predicate that reads them.
  it 'stays true after a provider switch, because the provider check asks about itself' do
    organisation = create(:organisation, ai_provider: 'anthropic', ai_access_token: 'sk-ant-key')
    organisation.update!(ai_provider: AiCredential::PROVIDER_GOOGLE)

    expect(organisation.ai_custom_access_configured?).to be(true)
  end

  # ⚠️ Its own question, not the switch. An organisation can have its access fully set
  # up while AI is off — that is the intended order of the area (prepare, then activate),
  # so a predicate that folded ai_enabled? in would report "nothing set up" for every
  # organisation doing it in the right order.
  it 'ignores the AI opt-in switch entirely' do
    organisation = create(:organisation, :ai_disabled, ai_provider: nil, ai_access_token: 'sk-live-key')

    expect(organisation.ai_custom_access_configured?).to be(true)
  end
end
