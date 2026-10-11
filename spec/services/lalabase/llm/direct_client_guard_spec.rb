# frozen_string_literal: true

# What: Guard spec — no LLM vendor client may be instantiated outside the
#   gated seams.
# Why (philosophy): The GDPR opt-in gate lives in Lalabase::Llm::Factory and
#   Organisation#ai_client. Both are only effective if every vendor client is
#   built behind them. config/initializers/open_ai.rb still configures a
#   process-global token, so a future bare `OpenAI::Client.new` anywhere in
#   app/ would silently pick it up and bypass BOTH the BYOK routing and the
#   opt-in gate. This spec turns that class of regression into a red test with
#   an actionable message instead of a silent compliance hole.
# Contract: vendor client constructors appear ONLY in the allowlisted seams.

require 'rails_helper'

RSpec.describe 'LLM vendor client instantiation guard' do
  # The gated seams. Anything new goes through Lalabase::Llm::Factory instead of
  # joining this list — shrink-only, it never grows back. Two entries have
  # already left: Organisation#ai_client in S2 (the legacy chat seam is gone),
  # and AiCredential#client_instance, whose only caller — the per-model
  # #test_connection — now probes through a Factory-built provider instead
  # (AiCredentialConnectivity). Only the providers themselves remain.
  ALLOWED_CLIENT_FILES = %w[
    app/services/lalabase/llm/open_ai_provider.rb
    app/services/lalabase/llm/open_ai_compatible_provider.rb
    app/services/lalabase/llm/anthropic_provider.rb
    app/services/lalabase/llm/google_vertex_provider.rb
  ].freeze

  # Google has no single vendor client class (the provider speaks REST via
  # Faraday) — its gate-relevant constructor is the service-account credential
  # mint: without Google::Auth there is no Vertex token, so matching it covers
  # the whole vendor path. A bare Faraday.new is NOT matched (Faraday serves
  # non-LLM HTTP all over the app).
  CLIENT_PATTERN = /OpenAI::Client\.new|Anthropic::Client\.new|Google::Auth::ServiceAccountCredentials/

  it 'finds vendor client constructors only in the allowlisted gated seams' do
    offenders = Dir.glob(Rails.root.join('app/**/*.rb')).select do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      next false if ALLOWED_CLIENT_FILES.include?(relative)

      File.read(path).match?(CLIENT_PATTERN)
    end

    expect(offenders).to be_empty, <<~MSG
      Direct LLM client instantiation outside the gated seams:
      #{offenders.join("\n")}
      Route the call through Lalabase::Llm::Factory (chat: for_chat /
      embeddings: for_embeddings) so the GDPR opt-in gate and BYOK routing apply.
    MSG
  end

  it 'still sees the allowlisted seams (guard must not go stale)' do
    # If a seam file is renamed/deleted (or an allowlist entry stops matching
    # the pattern), the guard silently shrinks and the first test passes
    # vacuously — pin that EVERY entry exists and matches. This also forces a
    # pattern extension when a new vendor path is allowlisted (allowlist-only
    # additions would leave the vendor path uncovered elsewhere).
    matching = ALLOWED_CLIENT_FILES.select do |relative|
      path = Rails.root.join(relative)
      File.exist?(path) && File.read(path).match?(CLIENT_PATTERN)
    end
    expect(matching).to match_array(ALLOWED_CLIENT_FILES)
  end
end
