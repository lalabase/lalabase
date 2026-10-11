# frozen_string_literal: true

module Webhooks
  # Receives GitHub push webhooks and triggers an incremental re-index
  # (RepoReindexJob) for the affected repository.
  #
  # Security model:
  # - Public endpoint (no session, no CSRF). The ONLY proof of authenticity is
  #   the per-repo HMAC secret, verified over the RAW request body.
  # - Lookup runs WITHOUT a tenant: a webhook carries no session, so the repo
  #   UUID in the path is the sole identifier.
  # - "Repo not found", "no secret configured", "missing signature" and "bad
  #   signature" ALL return a bare 401 with no body, so the response can't be
  #   used to discover which repo UUIDs exist (no enumeration oracle).
  # - The payload is parsed and trusted only AFTER the signature verifies.
  class RepositoriesController < ApplicationController
    GITHUB_EVENT_HEADER     = 'X-GitHub-Event'
    GITHUB_SIGNATURE_HEADER = 'X-Hub-Signature-256'
    SIGNATURE_PREFIX        = 'sha256='
    PUSH_EVENT              = 'push'
    # GitHub sends this all-zero SHA as `after` when a branch is deleted. There
    # is no commit to clone/index at that ref, so we accept-and-ignore it
    # instead of enqueuing a job that would only fail on checkout.
    BLANK_SHA = ('0' * 40).freeze

    skip_before_action :verify_authenticity_token
    skip_before_action :authenticate_user!

    def create
      repo = find_repository
      return reject unless repo && valid_signature?(repo)

      # Signature verified — the body is now trusted.
      return head :no_content unless github_event == PUSH_EVENT

      payload = JSON.parse(raw_body)
      return head :no_content unless default_branch_push?(repo, payload)

      after_sha = payload['after'].to_s
      return head :no_content if ignorable_sha?(after_sha)

      RepoReindexJob.perform_later(repo, after_sha: after_sha)
      head :accepted
    rescue JSON::ParserError
      head :bad_request
    end

    private

    def find_repository
      ActsAsTenant.without_tenant { ProjectRepository.find_by(id: params[:id]) }
    end

    def valid_signature?(repo)
      secret = repo.webhook_secret
      return false if secret.blank? # legacy repo never set up → cannot authenticate

      received = request.headers[GITHUB_SIGNATURE_HEADER].to_s
      return false if received.blank?

      expected = SIGNATURE_PREFIX + OpenSSL::HMAC.hexdigest('SHA256', secret, raw_body)
      ActiveSupport::SecurityUtils.secure_compare(received, expected)
    end

    def default_branch_push?(repo, payload)
      payload['ref'] == "refs/heads/#{repo.default_branch}"
    end

    def ignorable_sha?(sha)
      sha.blank? || sha == BLANK_SHA
    end

    def github_event
      request.headers[GITHUB_EVENT_HEADER].to_s
    end

    # Raw body bytes for the HMAC — NEVER the parsed params: the signature is
    # over the exact bytes GitHub sent. Memoised + rewound so the verification
    # and the later JSON.parse read the same bytes.
    def raw_body
      @raw_body ||= request.body.read.tap { request.body.rewind }
    end

    def reject
      Rails.logger.warn("Webhooks::Repositories rejected id=#{params[:id]} from #{request.remote_ip}")
      head :unauthorized
    end
  end
end
