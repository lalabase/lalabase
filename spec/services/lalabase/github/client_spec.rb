# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lalabase::Github::Client do
  let(:conn) { double('Faraday::Connection') }
  subject(:client) { described_class.new(token: 'ghp-test', connection: conn) }

  def stub_response(status:, body:)
    double('Response', status: status, body: body.is_a?(Hash) ? body.to_json : body)
  end

  describe 'error hierarchy' do
    %i[AuthError NotFoundError RateLimitError InvalidScopeError].each do |sym|
      it "#{sym} descends from Error (single rescue catches it)" do
        expect(described_class.const_get(sym).ancestors).to include(described_class::Error)
      end
    end

    it 'Error descends from StandardError' do
      expect(described_class::Error.ancestors).to include(StandardError)
    end
  end

  describe '#validate_token!' do
    it 'returns {login:, id:} on 200' do
      allow(conn).to receive(:get).with('/user')
                                  .and_return(stub_response(status: 200, body: { 'login' => 'alice', 'id' => 42 }))
      expect(client.validate_token!).to eq(login: 'alice', id: 42)
    end

    # Catches mutation: `200..299` shrunk to `200..200` or `200..210` etc.
    [201, 204, 299].each do |status|
      it "treats #{status} as success (boundary on 200..299 range)" do
        allow(conn).to receive(:get).with('/user')
                                    .and_return(stub_response(status: status, body: { 'login' => 'a', 'id' => 1 }))
        expect { client.validate_token! }.not_to raise_error
      end
    end

    # Catches mutation: bumping success range to include 3xx.
    it 'treats 300 as an error (boundary just above success range)' do
      allow(conn).to receive(:get).with('/user')
                                  .and_return(stub_response(status: 300, body: { 'message' => 'redirect' }))
      expect { client.validate_token! }.to raise_error(described_class::Error)
    end

    it 'maps 401 → AuthError with the API-provided message' do
      allow(conn).to receive(:get).with('/user')
                                  .and_return(stub_response(status: 401, body: { 'message' => 'Bad credentials' }))
      expect { client.validate_token! }.to raise_error(described_class::AuthError, /Bad credentials/)
    end

    it 'maps 403 with "rate limit" message → RateLimitError' do
      allow(conn).to receive(:get).with('/user')
                                  .and_return(stub_response(status: 403, body: { 'message' => 'API rate limit exceeded' }))
      expect { client.validate_token! }.to raise_error(described_class::RateLimitError)
    end

    # Catches mutation: `/rate limit/i` → `/rate limit/` (drop the `i` flag).
    # GitHub error messages use varied casing across endpoints.
    it 'maps 403 with case-varied "RATE LIMIT" message → RateLimitError' do
      allow(conn).to receive(:get).with('/user')
                                  .and_return(stub_response(status: 403, body: { 'message' => 'Secondary RATE LIMIT exceeded' }))
      expect { client.validate_token! }.to raise_error(described_class::RateLimitError)
    end

    it 'maps 403 without rate-limit hint → InvalidScopeError' do
      allow(conn).to receive(:get).with('/user')
                                  .and_return(stub_response(status: 403, body: { 'message' => 'Resource not accessible by personal access token' }))
      expect { client.validate_token! }.to raise_error(described_class::InvalidScopeError)
    end

    it 'maps 500 → generic Error (defense in depth on unknown statuses)' do
      allow(conn).to receive(:get).with('/user')
                                  .and_return(stub_response(status: 500, body: { 'message' => 'oops' }))
      expect { client.validate_token! }.to raise_error(described_class::Error, /500/)
    end
  end

  describe '#fetch_repo_metadata!' do
    let(:repo_body) do
      { 'id' => 12_345, 'full_name' => 'acme/backend', 'default_branch' => 'main', 'private' => true }
    end

    it 'returns repo metadata as a hash with stringified id' do
      allow(conn).to receive(:get).with('/repos/acme/backend')
                                  .and_return(stub_response(status: 200, body: repo_body))
      result = client.fetch_repo_metadata!('acme/backend')
      expect(result).to eq(provider_repo_id: '12345', full_name: 'acme/backend',
                           default_branch: 'main', private: true)
    end

    it 'parses owner and repo from the full_name (slash split)' do
      allow(conn).to receive(:get).with('/repos/acme/repo-name')
                                  .and_return(stub_response(status: 200, body: repo_body))
      client.fetch_repo_metadata!('acme/repo-name')
      expect(conn).to have_received(:get).with('/repos/acme/repo-name')
    end

    %w[invalid acme/ /repo].each do |bad|
      it "rejects malformed full_name #{bad.inspect} without making any HTTP call" do
        expect(conn).not_to receive(:get)
        expect { client.fetch_repo_metadata!(bad) }.to raise_error(described_class::Error)
      end
    end

    it 'rejects empty full_name' do
      expect(conn).not_to receive(:get)
      expect { client.fetch_repo_metadata!('') }.to raise_error(described_class::Error, /required/)
    end

    it 'rejects nil full_name' do
      expect(conn).not_to receive(:get)
      expect { client.fetch_repo_metadata!(nil) }.to raise_error(described_class::Error)
    end

    it 'maps 404 → NotFoundError' do
      allow(conn).to receive(:get).with('/repos/acme/missing')
                                  .and_return(stub_response(status: 404, body: { 'message' => 'Not Found' }))
      expect { client.fetch_repo_metadata!('acme/missing') }.to raise_error(described_class::NotFoundError)
    end

    it 'tolerates non-JSON 500 bodies (no double-fault)' do
      allow(conn).to receive(:get).with('/repos/acme/backend')
                                  .and_return(stub_response(status: 500, body: '<html>oops</html>'))
      expect { client.fetch_repo_metadata!('acme/backend') }.to raise_error(described_class::Error)
    end

    it 'tolerates a completely empty body (no JSON parse exception escape)' do
      allow(conn).to receive(:get).with('/repos/acme/backend')
                                  .and_return(stub_response(status: 500, body: ''))
      expect { client.fetch_repo_metadata!('acme/backend') }.to raise_error(described_class::Error)
    end

    # split('/', 2) limits to 2 chunks → 'owner/sub/repo' yields owner='owner',
    # repo='sub/repo'. We must NOT crash before the HTTP call; GitHub then 404s.
    it 'passes paths containing slashes in the repo segment to GitHub unmodified' do
      allow(conn).to receive(:get).with('/repos/owner/sub/repo')
                                  .and_return(stub_response(status: 404, body: { 'message' => 'Not Found' }))
      expect { client.fetch_repo_metadata!('owner/sub/repo') }.to raise_error(described_class::NotFoundError)
    end
  end

  describe '#changed_files' do
    let(:compare_body) do
      {
        'files' => [
          { 'filename' => 'app/a.rb', 'status' => 'modified' },
          { 'filename' => 'app/new.rb', 'status' => 'added' },
          { 'filename' => 'app/gone.rb', 'status' => 'removed' },
          { 'filename' => 'app/renamed.rb', 'previous_filename' => 'app/old.rb', 'status' => 'renamed' }
        ]
      }
    end

    it 'calls the Compare API with base...head and maps files to {filename, previous_filename, status}' do
      allow(conn).to receive(:get).with('/repos/acme/backend/compare/sha-base...sha-head')
                                  .and_return(stub_response(status: 200, body: compare_body))
      result = client.changed_files(full_name: 'acme/backend', base: 'sha-base', head: 'sha-head')
      expect(result).to eq([
                             { filename: 'app/a.rb', previous_filename: nil, status: 'modified' },
                             { filename: 'app/new.rb', previous_filename: nil, status: 'added' },
                             { filename: 'app/gone.rb', previous_filename: nil, status: 'removed' },
                             { filename: 'app/renamed.rb', previous_filename: 'app/old.rb', status: 'renamed' }
                           ])
    end

    it 'returns [] when the compare response has no files key (identical refs)' do
      allow(conn).to receive(:get).and_return(stub_response(status: 200, body: { 'status' => 'identical' }))
      expect(client.changed_files(full_name: 'acme/backend', base: 'x', head: 'y')).to eq([])
    end

    it 'maps 404 → NotFoundError (unknown base/head)' do
      allow(conn).to receive(:get).and_return(stub_response(status: 404, body: { 'message' => 'Not Found' }))
      expect { client.changed_files(full_name: 'acme/backend', base: 'x', head: 'y') }
        .to raise_error(described_class::NotFoundError)
    end

    it 'rejects a malformed full_name without an HTTP call' do
      expect(conn).not_to receive(:get)
      expect { client.changed_files(full_name: 'nope', base: 'x', head: 'y') }.to raise_error(described_class::Error)
    end

    # The reindex job decides what each status means; the client must pass the
    # raw GitHub status through untouched (no whitelist/normalisation here).
    it 'passes every GitHub file status through verbatim' do
      all_statuses = %w[added modified removed renamed copied changed unchanged]
      body = { 'files' => all_statuses.map { |st| { 'filename' => "f-#{st}.rb", 'status' => st } } }
      allow(conn).to receive(:get).and_return(stub_response(status: 200, body: body))
      expect(client.changed_files(full_name: 'acme/backend', base: 'a', head: 'b').map { |f| f[:status] })
        .to eq(all_statuses)
    end

    # base...head order matters — a head...base swap yields the inverse diff.
    it 'requests base...head in that exact order (not head...base)' do
      allow(conn).to receive(:get).and_return(stub_response(status: 200, body: { 'files' => [] }))
      client.changed_files(full_name: 'acme/backend', base: 'OLD', head: 'NEW')
      expect(conn).to have_received(:get).with('/repos/acme/backend/compare/OLD...NEW')
    end
  end

  describe '#latest_commit_sha' do
    it 'resolves a branch to its HEAD commit SHA via the commits endpoint' do
      allow(conn).to receive(:get).with('/repos/acme/backend/commits/main')
                                  .and_return(stub_response(status: 200, body: { 'sha' => 'deadbeef123', 'commit' => {} }))
      expect(client.latest_commit_sha(full_name: 'acme/backend', branch: 'main')).to eq('deadbeef123')
    end

    # The branch segment is part of the path — a wrong branch resolves the wrong
    # HEAD. Pin that it is passed through verbatim (no default to 'main').
    it 'requests the exact branch given (not a hardcoded default)' do
      allow(conn).to receive(:get).and_return(stub_response(status: 200, body: { 'sha' => 'x' }))
      client.latest_commit_sha(full_name: 'acme/backend', branch: 'develop')
      expect(conn).to have_received(:get).with('/repos/acme/backend/commits/develop')
    end

    it 'maps 404 → NotFoundError (unknown branch)' do
      allow(conn).to receive(:get).and_return(stub_response(status: 404, body: { 'message' => 'No commit found' }))
      expect { client.latest_commit_sha(full_name: 'acme/backend', branch: 'gone') }
        .to raise_error(described_class::NotFoundError)
    end

    it 'maps 401 → AuthError (expired token) so the caller can fall back' do
      allow(conn).to receive(:get).and_return(stub_response(status: 401, body: { 'message' => 'Bad credentials' }))
      expect { client.latest_commit_sha(full_name: 'acme/backend', branch: 'main') }
        .to raise_error(described_class::AuthError)
    end

    it 'rejects a malformed full_name without an HTTP call' do
      expect(conn).not_to receive(:get)
      expect { client.latest_commit_sha(full_name: 'nope', branch: 'main') }.to raise_error(described_class::Error)
    end
  end

  # The single get() wrapper maps transport-level Faraday failures onto our Error
  # hierarchy so callers catch them with ONE rescue. Without it a bare
  # Faraday::TimeoutError escapes RepoReindexJob#perform, bypassing the
  # run-history/redaction contract (it rescues only Client::Error).
  describe 'transport-error wrapping (Faraday::Error → Client::Error)' do
    it 'wraps a Faraday transport timeout as Client::Error' do
      allow(conn).to receive(:get).and_raise(Faraday::TimeoutError)
      expect { client.validate_token! }.to raise_error(described_class::Error)
    end

    it 'wraps it on the changed_files path too (the caller that depends on it)' do
      allow(conn).to receive(:get).and_raise(Faraday::ConnectionFailed.new('boom'))
      expect { client.changed_files(full_name: 'acme/backend', base: 'a', head: 'b') }
        .to raise_error(described_class::Error)
    end

    # Only e.class is wrapped, never e.message — a Faraday message can carry the
    # request URL; assert it does not leak into the surfaced error.
    it 'does not leak request detail (e.message) into the wrapped error' do
      allow(conn).to receive(:get)
        .and_raise(Faraday::ConnectionFailed.new('https://api.github.com/user failed: detail'))
      expect { client.validate_token! }
        .to raise_error(described_class::Error) { |e| expect(e.message).not_to include('api.github.com') }
    end
  end

  describe 'default Faraday connection (no injection)' do
    it 'sends Authorization, Accept and User-Agent headers' do
      real_client = described_class.new(token: 'ghp-X')
      headers = real_client.send(:connection).headers
      expect(headers['Authorization']).to eq('token ghp-X')
      expect(headers['Accept']).to eq('application/vnd.github+json')
      expect(headers['User-Agent']).to eq('Lalabase/1.0')
    end

    # Catches mutation: `"token #{@token}"` → `"Bearer #{@token}"` (different auth scheme,
    # silently breaks against GitHub PATs).
    it 'uses the "token " scheme prefix, not "Bearer"' do
      real_client = described_class.new(token: 'XYZ')
      auth = real_client.send(:connection).headers['Authorization']
      expect(auth).to start_with('token ')
      expect(auth).not_to start_with('Bearer')
    end

    it 'BASE_URL is locked to https://api.github.com (catches accidental staging-url edits)' do
      expect(described_class::BASE_URL).to eq('https://api.github.com')
    end

    # Catches mutation: bumping timeouts (e.g. to 60s) silently degrades worker
    # throughput when GitHub stalls.
    it 'locks per-request and connection-open timeouts (DoS-resistance contract)' do
      real_client = described_class.new(token: 'X')
      opts = real_client.send(:connection).options
      expect(opts.timeout).to eq(8)
      expect(opts.open_timeout).to eq(4)
    end
  end
end
