# frozen_string_literal: true

require 'rails_helper'

# One marker per provider the disclosure duty attaches to. Local variables,
# not constants: the describe-time example loop and the it-blocks both capture
# them through the closure (instance_exec swaps self, not the lexical scope),
# while a top-level constant would leak into Object for the whole suite
# (pre-landing review, point 5). Keys mirror the code's offering
# (classify-or-explain: the completeness examples fail on any key added to or
# removed from the code without a row here).
#
# Each marker is the FORMAL recipient naming (company + legal form), not the
# bare brand: the page mentions "Google" while ruling out font transfers and
# "OpenAI" inside "OpenAI-kompatibel", so a brand-only marker would stay green
# with the actual provider section deleted — presence is not agreement (R5).
# Rewording a recipient line therefore requires touching this map; the failure
# message says so.
#
# 'openai_compatible' itself carries NO marker on purpose: the generic provider
# names no company — its curated shapes are the EU presets (each listed below),
# and its free-endpoint case is covered by the policy's own "eigene Endpunkte"
# section, where the ORG picks the recipient.
ai_provider_disclosure_markers = {
  'openai' => /OpenAI, L\.L\.C\./,
  'anthropic' => /Anthropic, PBC/,
  'google' => /Google Cloud EMEA Limited/
}.freeze

ai_preset_disclosure_markers = {
  'mistral' => /Mistral AI SAS/,
  'ionos' => /IONOS SE/,
  'ovhcloud' => /OVH SAS/
}.freeze

# KI-Pakete P5: the public privacy policy must NAME every AI provider this code
# base can offer — the page is static while the offering grows in code, and the
# July-2026 revision proved the drift is real: it still said "OpenAI + Anthropic"
# months after the EU presets and Vertex landed.
#
# What this guard IS: a presence check against the CODE's offering — the
# provider vocabulary (AiCredential::PROVIDERS) and the curated EU presets
# (EU_CHAT_PRESETS). CI cannot see which packages an operator has published in
# production, and it does not need to: packages are built out of exactly this
# vocabulary, and a privacy policy has to name what the instance CAN offer.
#
# What this guard is NOT (stated per the R5 lesson "presence is not
# agreement"): it cannot judge whether the legal prose next to a name — DPF
# status, SCC wording, addresses — is correct. That remains the lawyer review
# tracked in doc/agb_review_plan.md. This guard only guarantees no provider can
# be offered without the page mentioning it at all.
RSpec.describe 'AI providers the privacy policy on lalabase.com must name' do
  # The policy itself left the core with the public pages (website split, W6).
  # What stays here is the half only this repository can answer: WHICH providers
  # the code can offer. That the page names each of them is pinned over there,
  # against CoreFacts::AI_DISCLOSURE_NAMINGS, and
  # spec/architecture/website_quoted_facts_guard_spec.rb keeps that copy honest.
  #
  # Split rather than deleted: a disclosure duty does not stop existing because
  # the page moved, and this is the half that goes stale silently -- a provider
  # added to the code is invisible to a spec that only reads a page.

  describe 'completeness of the marker maps (classify-or-explain)' do
    it 'covers every provider in the vocabulary except the generic one' do
      expected = AiCredential::PROVIDERS - [AiCredential::PROVIDER_OPENAI_COMPATIBLE]

      expect(ai_provider_disclosure_markers.keys).to match_array(expected),
                                                     'Provider vocabulary and disclosure markers drifted apart: a ' \
                                                     'provider was added to (or removed from) AiCredential::PROVIDERS ' \
                                                     'without updating the privacy policy and this map.'
    end

    it 'covers every curated EU preset' do
      expect(ai_preset_disclosure_markers.keys).to match_array(AiCredential::EU_CHAT_PRESETS.keys),
                                                   'EU presets and disclosure markers drifted apart: a preset was ' \
                                                   'added to (or removed from) EU_CHAT_PRESETS without updating the ' \
                                                   'privacy policy and this map.'
    end
  end
end
