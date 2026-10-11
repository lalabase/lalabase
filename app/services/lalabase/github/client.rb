# frozen_string_literal: true

require 'faraday'
require 'json'

module Lalabase
  module Github
    # Thin GitHub REST API client for the repo-connect flow (M4).
    # Phase 1 needs only two calls:
    #   - validate_token! → GET /user (does this token authenticate at all?)
    #   - fetch_repo_metadata!(full_name) → GET /repos/:owner/:repo
    #
    # We deliberately do NOT use octokit — those two calls aren't worth the gem
    # overhead and an injected Faraday connection is easier to stub in specs.
    class Client
      BASE_URL = 'https://api.github.com'

      class Error           < StandardError; end
      class AuthError       < Error; end
      class NotFoundError   < Error; end
      class RateLimitError  < Error; end
      class InvalidScopeError < Error; end

      attr_reader :token

      def initialize(token:, connection: nil)
        @token = token
        @connection = connection
      end

      # @return [Hash] { login:, id: }
      def validate_token!
        response = get('/user')
        handle_response!(response)
        body = parse(response)
        { login: body['login'], id: body['id'] }
      end

      # @param full_name [String] e.g. "acme/backend"
      # @return [Hash] { provider_repo_id:, full_name:, default_branch:, private: }
      def fetch_repo_metadata!(full_name)
        owner, repo = split_full_name!(full_name)
        response = get("/repos/#{owner}/#{repo}")
        handle_response!(response)
        body = parse(response)
        {
          provider_repo_id: body['id'].to_s,
          full_name: body['full_name'],
          default_branch: body['default_branch'],
          private: body['private']
        }
      end

      # Current tip commit SHA of a branch (GET /repos/:owner/:repo/commits/:ref,
      # which resolves a branch name to its HEAD commit). Used by the MANUAL
      # re-index trigger: a webhook carries the pushed SHA in its payload, but a
      # user-initiated "reindex now" has no payload — so we resolve the branch head
      # here and feed it to the same incremental path as the webhook.
      #
      # @param branch [String] e.g. "main"
      # @return [String] the 40/64-char commit SHA
      def latest_commit_sha(full_name:, branch:)
        owner, repo = split_full_name!(full_name)
        response = get("/repos/#{owner}/#{repo}/commits/#{branch}")
        handle_response!(response)
        parse(response)['sha']
      end

      # Files changed between two commits/refs via the Compare API
      # (GET /repos/:owner/:repo/compare/:base...:head). Used by the incremental
      # re-index path: base = last indexed commit, head = pushed commit. base/head
      # should be commit SHAs or simple refs.
      #
      # GitHub caps the `files` array at 300 entries; for a larger push the caller
      # should fall back to a full re-index.
      #
      # @return [Array<Hash>] { filename:, previous_filename:, status: }
      #   status ∈ added | modified | removed | renamed | copied | changed | unchanged
      def changed_files(full_name:, base:, head:)
        owner, repo = split_full_name!(full_name)
        response = get("/repos/#{owner}/#{repo}/compare/#{base}...#{head}")
        handle_response!(response)
        Array(parse(response)['files']).map do |f|
          { filename: f['filename'], previous_filename: f['previous_filename'], status: f['status'] }
        end
      end

      private

      # Validates here even though ProjectRepository#full_name already enforces
      # FULL_NAME_PATTERN: this client also runs during the connect flow
      # (fetch_repo_metadata! BEFORE a repo row exists, so the model guard hasn't
      # run) and from tests with raw strings. Cheap defense so a malformed name
      # can never reach the request path.
      def split_full_name!(full_name)
        raise Error, 'full_name required' if full_name.to_s.strip.empty?

        owner, repo = full_name.split('/', 2)
        raise Error, "invalid full_name #{full_name.inspect}" if owner.nil? || repo.nil? || owner.empty? || repo.empty?

        [owner, repo]
      end

      def connection
        @connection ||= Faraday.new(url: BASE_URL) do |conn|
          conn.headers['Authorization'] = "token #{@token}"
          conn.headers['Accept']        = 'application/vnd.github+json'
          conn.headers['User-Agent']    = 'Lalabase/1.0'
          conn.options.timeout      = 8
          conn.options.open_timeout = 4
        end
      end

      # Wraps connection.get so transport-level Faraday failures (timeout, reset,
      # DNS) surface as our Client::Error instead of escaping raw. Callers only
      # rescue Client::Error; a bare Faraday::TimeoutError would otherwise bypass
      # the caller's run-history/redaction contract (see RepoReindexJob). Only the
      # error class is included, never e.message, so no URL/header detail leaks.
      def get(path)
        connection.get(path)
      rescue Faraday::Error => e
        raise Error, "GitHub request failed (#{e.class})"
      end

      def handle_response!(response)
        case response.status
        when 200..299 then nil
        when 401      then raise AuthError, parse(response)['message'] || 'unauthorized'
        when 403
          msg = parse(response)['message'].to_s
          raise RateLimitError, msg if msg.match?(/rate limit/i)

          raise InvalidScopeError, msg
        when 404 then raise NotFoundError, parse(response)['message'] || 'not found'
        else
          raise Error, "GitHub API error #{response.status}: #{parse(response)['message']}"
        end
      end

      def parse(response)
        return {} if response.body.to_s.empty?

        JSON.parse(response.body)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
