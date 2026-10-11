# frozen_string_literal: true

require 'rails_helper'

# What:  The direct-upload endpoint only serves signed-in users, refuses oversized
#        blobs and is throttled per user; the byte channel (disk PUT) is throttled per IP.
# Type:  Request spec (security guard, 2026-08-23).
# Why:   ActiveStorage::DirectUploadsController sits outside ApplicationController.
#        Before DirectUploadsGuard an anonymous POST created a blob row and a signed
#        PUT URL for the file (finding F5, doc/inline_bilder_spike_plan.md): disk space
#        anyone on the internet could fill, swept only seven days later. The throttle
#        is matched format-tolerantly like every other Rack::Attack path (the .json and
#        trailing-slash bypass class, see auth_throttle_spec).
RSpec.describe 'Direct uploads guard', type: :request do
  let(:path) { '/rails/active_storage/direct_uploads' }
  let(:json_headers) { { 'Content-Type' => 'application/json', 'Accept' => 'application/json' } }

  def blob_payload(byte_size: 5)
    { blob: { filename: 'shot.png', byte_size: byte_size, checksum: 'XUFAKrxLKna5cZ2REBfFkg==',
              content_type: 'image/png' } }.to_json
  end

  def post_upload(byte_size: 5, at: path)
    post at, params: blob_payload(byte_size: byte_size), headers: json_headers
  end

  describe 'anonymous' do
    it 'answers 401 and creates no blob' do
      expect { post_upload }.not_to change(ActiveStorage::Blob, :count)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'signed in' do
    before { sign_in create(:user) }

    it 'creates the blob and returns the direct-upload instructions' do
      expect { post_upload }.to change(ActiveStorage::Blob, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('signed_id', 'direct_upload')
    end

    it 'accepts exactly the ceiling' do
      expect { post_upload(byte_size: DirectUploadsGuard::MAX_BYTE_SIZE) }
        .to change(ActiveStorage::Blob, :count).by(1)
      expect(response).to have_http_status(:ok)
    end

    it 'refuses one byte above the ceiling without creating a blob' do
      expect { post_upload(byte_size: DirectUploadsGuard::MAX_BYTE_SIZE + 1) }
        .not_to change(ActiveStorage::Blob, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    # The codebase import direct-uploads its archive (1 GB limit) through this endpoint;
    # a ceiling below that limit breaks every archive import above the ceiling.
    it 'is not below the codebase archive limits' do
      expect(DirectUploadsGuard::MAX_BYTE_SIZE)
        .to be >= [CodebaseImportFile::MAX_TAR_FILE_SIZE, CodebaseImportFile::MAX_ZIP_FILE_SIZE].max
    end

    # A scalar `blob` used to raise TypeError in params.dig (500 with a backtrace in the
    # error tracker); the guard now steps aside and ActiveStorage answers 400 as before.
    it 'leaves a malformed blob param to Rails (400, not 500)' do
      expect { post path, params: { blob: 'x' }.to_json, headers: json_headers }
        .not_to change(ActiveStorage::Blob, :count)
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'throttle (direct_uploads/user, 60 per minute)' do
    include ActiveSupport::Testing::TimeHelpers

    around do |example|
      enabled_was = Rack::Attack.enabled
      store_was = Rack::Attack.cache.store
      Rack::Attack.enabled = true
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      # Frozen clock, because Rack::Attack counts in DISCRETE period buckets:
      # the counter key carries (Time.now.to_i / period). A burst of 61 requests
      # that straddles a minute boundary therefore lands in TWO buckets, and the
      # 61st request is the 1st of a fresh allowance -- 200 instead of 429, and
      # this guard reads as broken on a tree where nothing is.
      #
      # Not hypothetical: run 33023426866 went red here on a green tree and green
      # on a re-run of the SAME sha. Where in the wall-clock minute the example
      # starts is not something a guard may depend on, and it changes whenever
      # anything above it in the curated list gets longer.
      freeze_time { example.run }
      Prosopite.resume
      Rack::Attack.cache.store = store_was
      Rack::Attack.enabled = enabled_was
    end

    before do
      Prosopite.pause
      sign_in create(:user)
    end

    it 'lets 60 uploads through and throttles the 61st' do
      60.times { post_upload }
      expect(response).to have_http_status(:ok)

      post_upload
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'cannot be bypassed with a format suffix' do
      60.times { post_upload }
      post_upload(at: "#{path}.json")
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'cannot be bypassed with a trailing slash' do
      60.times { post_upload }
      post_upload(at: "#{path}/")
      expect(response).to have_http_status(:too_many_requests)
    end

    # The unit is the signed-in user, not the address: an office behind one NAT must not
    # share a single allowance. Mutation guard: keying on req.ip alone fails this.
    it 'counts per user, not per address' do
      60.times { post_upload }
      expect(response).to have_http_status(:ok)

      sign_in create(:user)
      post_upload
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'throttle on the byte channel (disk_uploads/ip, 60 per minute)' do
    let(:disk_path) { '/rails/active_storage/disk/not-a-real-token' }

    around do |example|
      enabled_was = Rack::Attack.enabled
      store_was = Rack::Attack.cache.store
      Rack::Attack.enabled = true
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      example.run
      Prosopite.resume
      Rack::Attack.cache.store = store_was
      Rack::Attack.enabled = enabled_was
    end

    before { Prosopite.pause }

    # The PUT carries a signed token and no session; an invalid token answers 404, which
    # is enough to count. The 61st PUT from one address is throttled regardless.
    it 'lets 60 PUTs through and throttles the 61st' do
      60.times { put disk_path, params: 'bytes', headers: { 'Content-Type' => 'application/octet-stream' } }
      expect(response).to have_http_status(:not_found)

      put disk_path, params: 'bytes', headers: { 'Content-Type' => 'application/octet-stream' }
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'does not count the token POST against the byte channel' do
      sign_in create(:user)
      60.times { post_upload }
      put disk_path, params: 'bytes', headers: { 'Content-Type' => 'application/octet-stream' }
      expect(response).to have_http_status(:not_found)
    end
  end
end
