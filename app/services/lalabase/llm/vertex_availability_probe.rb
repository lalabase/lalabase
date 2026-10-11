# frozen_string_literal: true

require 'faraday'
require 'json'

# Probes Vertex AI model availability per (region × model) for one google
# credential — cost-free via :countTokens (no inference, no write, no tokens
# billed, no tenant content: the payload is the literal "ping"). Results are
# cached per credential; admin-only diagnostic surface behind the beuser
# session (doc/vertex_model_availability_plan.md).
#
# Deliberately NOT an Actor (pure read, no domain write) and NOT behind the
# quota seam (countTokens is free and runs without any org context).
module Lalabase
  module Llm
    class VertexAvailabilityProbe
      class ProbeError < StandardError; end

      # Curated probe targets (as of 2026-07-18) — model availability shifts
      # per EU region and over time (see the Vertex section of
      # <https://lalabase.com/docs/de/self-hosting/configuration/ai-byok>, whose source lives
      # in gboyke/lalabase-documentation since D5).
      # Configurability via system setting = v2. gemini-2.0-flash stays in the
      # list although Google has retired it: it was DEFAULT_CHAT_MODEL until
      # 2026-07-31 and is still carried by credentials created back then, so an
      # all-red 2.0-flash column IS the actionable finding ("move that
      # credential to a current model").
      EU_REGIONS        = %w[europe-west1 europe-west3 europe-west4 europe-west9].freeze
      INFO_ONLY_REGIONS = %w[global].freeze # runtime provider REJECTS global (residency)
      PROBE_REGIONS     = (EU_REGIONS + INFO_ONLY_REGIONS).freeze

      CANDIDATE_MODELS = %w[
        gemini-2.5-flash
        gemini-2.5-pro
        gemini-2.5-flash-lite
        gemini-2.0-flash
        gemini-embedding-001
      ].freeze

      # countTokens does not apply to embedding models: a PRESENT embedding
      # model answers 400 ("Should provide instances for text model
      # prediction."), an ABSENT one answers 404 exactly like the generative
      # path (verified against a live project 2026-07-18, plan §14 #1). Models
      # matching this pattern therefore count 400 as "available" — the ONE
      # asymmetry to the generative interpretation. :predict is deliberately
      # not used (billed, real inference).
      EMBEDDING_MODEL_PATTERN = /embedding/

      # Cost-free probe body — countTokens performs no inference and no write.
      PING_PAYLOAD = { contents: [{ role: 'user', parts: [{ text: 'ping' }] }] }.freeze

      MAX_CONCURRENCY = 8
      OPEN_TIMEOUT_SECONDS = 2
      REQUEST_TIMEOUT_SECONDS = 5
      CACHE_TTL = 1.hour

      class << self
        # Entry point: probe all (region × model) combos, or return the cached
        # matrix; force_refresh bypasses the cache read and overwrites it.
        def call(credential_id:, force_refresh: false)
          credential = load_google_credential!(credential_id)
          key = cache_key(credential)

          unless force_refresh
            hit = Rails.cache.read(key)
            return hit if hit
          end

          result = probe_matrix(credential)
          Rails.cache.write(key, result, expires_in: CACHE_TTL)
          result
        end

        # Pure cache read for the show page — never triggers network I/O.
        def cached(credential_id:)
          cached_for(credential: ::AiCredential.find(credential_id))
        end

        # Same read for callers that ALREADY hold the record — the package show
        # page eager-loads every referenced credential, so going back through
        # #cached would re-SELECT one row per google slot just to rebuild a key
        # the caller could hand over.
        def cached_for(credential:)
          Rails.cache.read(cache_key(credential))
        end

        # One place for the key format. The updated_at component auto-invalidates
        # when the credential is edited (new project/token ⇒ stale matrix gone).
        def cache_key(credential)
          "vertex_availability/v1/#{credential.id}-#{credential.updated_at.to_i}"
        end

        private

        # Loads via the RUNTIME model deliberately: AiCredential declares
        # `encrypts :access_token`, Admin::AiCredential does not — reading an
        # encrypted row through the admin model would yield ciphertext (plan §3).
        def load_google_credential!(credential_id)
          credential = ::AiCredential.find_by(id: credential_id)
          raise ProbeError, "AI credential #{credential_id} not found" unless credential

          raise ProbeError, "availability probe only supports google credentials (got '#{credential.provider}')" unless credential.provider == ::AiCredential::PROVIDER_GOOGLE
          raise ProbeError, 'credential has no service-account JSON in access_token' if credential.access_token.blank?
          raise ProbeError, "credential has no additional_config['project_id']" if credential.additional_config&.dig('project_id').to_s.strip.empty?

          credential
        end

        def probe_matrix(credential)
          project_id = credential.additional_config['project_id'].to_s.strip
          # Credential + token are read BEFORE the fan-out: the OAuth token is
          # region-independent (scope cloud-platform), and the worker threads
          # must never touch ActiveRecord (no pool pressure, no tenant context).
          # A failing mint raises AuthError here — no partial matrix, no cache.
          token = GoogleVertexProvider.mint_access_token(credential.access_token)
          models = probe_models(credential)

          {
            checked_at: Time.current,
            project_id: project_id,
            regions: PROBE_REGIONS,
            models: models,
            results: probe_all(PROBE_REGIONS.product(models), project_id: project_id, token: token)
          }
        end

        # The credential's own default_model joins the matrix (front, deduped) —
        # the matrix must always answer "does MY configured model work?".
        def probe_models(credential)
          extra = credential.default_model.to_s.strip
          return CANDIDATE_MODELS if extra.empty? || CANDIDATE_MODELS.include?(extra)

          ([extra] + CANDIDATE_MODELS).freeze
        end

        # Bounded worker pool (Thread + Queue, MAX_CONCURRENCY): one Faraday
        # connection per call, per-combo transport rescue in #probe_one so a
        # dead region never kills the matrix. Results come back in combo order
        # regardless of thread completion order.
        def probe_all(combos, project_id:, token:)
          queue = Queue.new
          combos.each { |combo| queue << combo }
          collected = Queue.new

          [MAX_CONCURRENCY, combos.size].min.times.map do
            Thread.new do
              while (combo = pop_nonblocking(queue))
                region, model = combo
                collected << probe_one(project_id: project_id, token: token, region: region, model: model)
              end
            end
          end.each(&:join)

          by_combo = {}
          by_combo[[(cell = collected.pop)[:region], cell[:model]]] = cell until collected.empty?
          combos.map { |region, model| by_combo[[region, model]] }
        end

        def pop_nonblocking(queue)
          queue.pop(true)
        rescue ThreadError
          nil
        end

        # One countTokens POST per (region, model). Only the status code is
        # interpreted — the body is never parsed. Transport failures yield
        # status_code nil (yellow cell), isolated to this one cell.
        def probe_one(project_id:, token:, region:, model:)
          path = GoogleVertexProvider.model_path_for(project_id: project_id, location: region,
                                                     model: model, action: :countTokens)
          response = build_connection(region).post(path) do |req|
            req.headers['Authorization'] = "Bearer #{token}"
            req.headers['Content-Type'] = 'application/json'
            req.body = JSON.generate(PING_PAYLOAD)
          end
          build_result(region: region, model: model, status_code: response.status)
        rescue Faraday::Error
          build_result(region: region, model: model, status_code: nil)
        rescue StandardError => e
          # Any other per-combo failure must stay isolated to its yellow cell —
          # a single dead combo may never 500 the whole diagnostic. Log the
          # unexpected class so a real bug is not swallowed silently.
          Rails.logger.warn("[vertex_availability] probe error #{region}/#{model}: #{e.class}: #{e.message}")
          build_result(region: region, model: model, status_code: nil)
        end

        # A fresh connection per call is cheap and sidesteps every question
        # about sharing Faraday::Connection instances across threads.
        def build_connection(region)
          Faraday.new(url: GoogleVertexProvider.endpoint_host_for(region)) do |conn|
            conn.options.open_timeout = OPEN_TIMEOUT_SECONDS
            conn.options.timeout = REQUEST_TIMEOUT_SECONDS
          end
        end

        # 200 → green, 404 → red, anything else (400/401/403/429/5xx or a
        # transport error) → yellow. Embedding models additionally count 400 as
        # "available" (see EMBEDDING_MODEL_PATTERN); the raw status_code stays
        # in the cell for tooltip/legend either way.
        def build_result(region:, model:, status_code:)
          {
            region: region,
            model: model,
            status_code: status_code,
            available: available_status?(model, status_code),
            info_only: INFO_ONLY_REGIONS.include?(region)
          }
        end

        def available_status?(model, status_code)
          return true if status_code == 200

          status_code == 400 && model.match?(EMBEDDING_MODEL_PATTERN)
        end
      end
    end
  end
end
