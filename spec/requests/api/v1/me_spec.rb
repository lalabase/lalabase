# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'API V1 Me', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  let(:pat) do
    pat = build(:personal_access_token, user: user, organisations: [organisation])
    pat.token_hash = nil
    pat.token_prefix = nil
    pat.generate_token!
    pat
  end

  def auth_headers(token)
    { 'Authorization' => "Bearer #{token}" }
  end

  describe 'GET /api/v1/me' do
    context 'authentication failures' do
      it 'returns 401 when no Authorization header is sent' do
        get '/api/v1/me'
        expect(response).to have_http_status(:unauthorized)
        expect(JSON.parse(response.body)['error']).to eq('unauthorized')
      end

      it 'returns 401 for an empty Bearer token' do
        get '/api/v1/me', headers: { 'Authorization' => 'Bearer ' }
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns 401 for a token with the wrong prefix' do
        get '/api/v1/me', headers: auth_headers('ghp_abc123xyz')
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns 401 for an unknown but well-formed token' do
        forged = "#{PersonalAccessToken::TOKEN_PREFIX}#{SecureRandom.alphanumeric(32)}"
        get '/api/v1/me', headers: auth_headers(forged)
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns 401 for a revoked token' do
        pat.revoke!
        get '/api/v1/me', headers: auth_headers(pat.token)
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns 401 for an expired token' do
        pat.update!(expires_at: 1.minute.ago)
        get '/api/v1/me', headers: auth_headers(pat.token)
        expect(response).to have_http_status(:unauthorized)
      end

      # The same 401 as an unknown token: a credential answers only while its
      # owner could sign in. The valid-token context below is the control.
      it 'returns 401 when the owner is locked' do
        user.lock_access!(send_instructions: false)
        get '/api/v1/me', headers: auth_headers(pat.token)
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns 401 when the owner is unconfirmed past the grace period' do
        # The grace period runs from created_at (User#confirmation_period_valid?).
        user.update_columns(confirmed_at: nil, created_at: (Devise.allow_unconfirmed_access_for + 1.day).ago)
        get '/api/v1/me', headers: auth_headers(pat.token)
        expect(response).to have_http_status(:unauthorized)
      end

      # Changing or resetting the password is how a person takes an account
      # back; a token minted by whoever had it must not survive that.
      it 'returns 401 after the owner changed the password' do
        token = pat.token # minted BEFORE the new password
        user.update!(password: 'a-new-password-123', password_confirmation: 'a-new-password-123')
        get '/api/v1/me', headers: auth_headers(token)
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns 401 after the owner reset the password' do
        token = pat.token # minted BEFORE the new password
        user.reset_password('a-new-password-123', 'a-new-password-123')
        get '/api/v1/me', headers: auth_headers(token)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with a valid token' do
      it 'returns 200 with user identity, token info and scope summary' do
        get '/api/v1/me', headers: auth_headers(pat.token)

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)

        expect(body.dig('data', 'user', 'id')).to eq(user.id)
        expect(body.dig('data', 'user', 'email')).to eq(user.email)

        expect(body.dig('data', 'token', 'id')).to eq(pat.id)
        expect(body.dig('data', 'token', 'name')).to eq(pat.name)
        expect(body.dig('data', 'token', 'prefix')).to eq(pat.token_prefix)
        # token plaintext must NEVER be in the response
        expect(response.body).not_to include(pat.token)

        orgs = body.dig('data', 'scoped_organisations')
        expect(orgs.size).to eq(1)
        expect(orgs.first['id']).to eq(organisation.id)
        expect(orgs.first['all_projects']).to be true
      end

      # A client decides before it offers a write whether the token may write
      # (terminal client plan, S0 b). Both values, so a constant cannot pass.
      it 'says whether the token is read-only' do
        pat.update!(read_only: false)
        get '/api/v1/me', headers: auth_headers(pat.token)
        expect(JSON.parse(response.body).dig('data', 'token', 'read_only')).to be false

        pat.update!(read_only: true)
        get '/api/v1/me', headers: auth_headers(pat.token)
        expect(JSON.parse(response.body).dig('data', 'token', 'read_only')).to be true
      end

      it 'updates last_used_at on the token' do
        pat.update!(last_used_at: nil)
        expect { get '/api/v1/me', headers: auth_headers(pat.token) }
          .to change { pat.reload.last_used_at }.from(nil)
      end

      it 'does not update last_used_at more often than once per minute' do
        pat.update!(last_used_at: 30.seconds.ago)
        previous = pat.reload.last_used_at
        get '/api/v1/me', headers: auth_headers(pat.token)
        expect(pat.reload.last_used_at).to be_within(0.1.seconds).of(previous)
      end

      it 'resets Current attributes after the request' do
        Current.user = nil
        get '/api/v1/me', headers: auth_headers(pat.token)
        expect(Current.user).to be_nil
      end

      it 'lists selected_projects when the org scope is restricted' do
        project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
        restricted = build(:personal_access_token, user: user)
        restricted.personal_access_token_organisations.build(
          organisation: organisation,
          all_projects: false
        )
        restricted.personal_access_token_projects.build(project: project)
        restricted.assign_token!
        restricted.save!

        get '/api/v1/me', headers: auth_headers(restricted.token)

        orgs = JSON.parse(response.body).dig('data', 'scoped_organisations')
        expect(orgs.first['all_projects']).to be false
        expect(orgs.first['scoped_project_ids']).to contain_exactly(project.id)
      end
    end
  end
end
