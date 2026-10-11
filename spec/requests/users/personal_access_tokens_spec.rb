# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Users::PersonalAccessTokens', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
  end

  describe 'GET /users/personal_access_tokens' do
    it 'lists the current user’s tokens' do
      pat = create(:personal_access_token, user: user, organisations: [organisation])
      get users_personal_access_tokens_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(pat.name)
    end

    it 'does not include tokens of other users' do
      other_user = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: other_user, organisation: organisation, role: role, active: true)
      end
      other_pat = create(:personal_access_token, user: other_user, organisations: [organisation])
      get users_personal_access_tokens_path
      expect(response.body).not_to include(other_pat.name)
    end
  end

  describe 'GET /users/personal_access_tokens/new' do
    it 'renders the multi-block form' do
      get new_users_personal_access_token_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.users.personal_access_tokens.new.block_organisations'))
      expect(response.body).to include(organisation.name)
    end
  end

  describe 'POST /users/personal_access_tokens' do
    let(:project) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end

    context 'with valid params and all_projects scope' do
      it 'creates the token and renders the plaintext exactly once' do
        expect do
          post users_personal_access_tokens_path, params: {
            current_password: user.password,
            personal_access_token: {
              name: 'Test token',
              expires_preset: '30',
              organisation_ids: [organisation.id],
              project_mode: { organisation.id => 'all' }
            }
          }
        end.to change(PersonalAccessToken, :count).by(1)
           .and change(PersonalAccessTokenOrganisation, :count).by(1)

        token = PersonalAccessToken.order(:created_at).last
        expect(token.name).to eq('Test token')
        expect(token.configured_organisations).to include(organisation)
        expect(token.personal_access_token_organisations.first.all_projects?).to be true
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(token.token_prefix)
      end
    end

    context 'with the read_only flag (D3)' do
      it 'creates a writable token when read-only is unchecked' do
        post users_personal_access_tokens_path, params: {
          current_password: user.password,
          personal_access_token: {
            name: 'Writable', read_only: '0', expires_preset: '30',
            organisation_ids: [organisation.id], project_mode: { organisation.id => 'all' }
          }
        }
        expect(PersonalAccessToken.find_by(name: 'Writable').read_only?).to be false
      end

      it 'keeps a created token read-only when the box stays checked' do
        post users_personal_access_tokens_path, params: {
          current_password: user.password,
          personal_access_token: {
            name: 'Default RO', read_only: '1', expires_preset: '30',
            organisation_ids: [organisation.id], project_mode: { organisation.id => 'all' }
          }
        }
        expect(PersonalAccessToken.find_by(name: 'Default RO').read_only?).to be true
      end
    end

    context 'with every organisation, including future ones' do
      it 'creates a token with the option and without organisation links' do
        post users_personal_access_tokens_path, params: {
          current_password: user.password,
          personal_access_token: {
            name: 'Everywhere', expires_preset: '30', organisation_mode: 'all',
            # A box still ticked from before the switch must not become a second meaning.
            organisation_ids: [organisation.id], project_mode: { organisation.id => 'all' }
          }
        }
        token = PersonalAccessToken.find_by!(name: 'Everywhere')
        expect(token.all_organisations?).to be(true)
        expect(token.personal_access_token_organisations).to be_empty
      end

      it 'keeps the per-organisation choice when the option is not taken' do
        post users_personal_access_tokens_path, params: {
          current_password: user.password,
          personal_access_token: {
            name: 'Picked', expires_preset: '30', organisation_mode: 'selected',
            organisation_ids: [organisation.id], project_mode: { organisation.id => 'all' }
          }
        }
        token = PersonalAccessToken.find_by!(name: 'Picked')
        expect(token.all_organisations?).to be(false)
        expect(token.configured_organisations).to contain_exactly(organisation)
      end

      it 'offers the option on the form, not preselected' do
        get new_users_personal_access_token_path
        page = Nokogiri::HTML(response.body)
        all = page.at_css('input[name="personal_access_token[organisation_mode]"][value="all"]')
        selected = page.at_css('input[name="personal_access_token[organisation_mode]"][value="selected"]')
        expect(all).to be_present
        expect(all['checked']).to be_nil
        expect(selected['checked']).to be_present
      end

      it 'keeps the choice when the form comes back with an error' do
        post users_personal_access_tokens_path, params: {
          current_password: 'wrong password',
          personal_access_token: { name: 'Everywhere', expires_preset: '30', organisation_mode: 'all' }
        }
        expect(response).to have_http_status(:unprocessable_content)
        page = Nokogiri::HTML(response.body)
        all = page.at_css('input[name="personal_access_token[organisation_mode]"][value="all"]')
        expect(all['checked']).to be_present
        expect(page.at_css('[data-neo-personal-access-token-form-target="organisationList"]')['class']).to include('hidden')
      end

      it 'groups the choice under its question, with the hint described, not labelled' do
        get new_users_personal_access_token_path
        page = Nokogiri::HTML(response.body)
        all = page.at_css('input[name="personal_access_token[organisation_mode]"][value="all"]')
        fieldset = all.ancestors('fieldset').first
        expect(fieldset&.at_css('legend')&.text&.strip)
          .to eq(I18n.t('views.users.personal_access_tokens.new.org_pick_label'))
        hint = page.at_css("##{all['aria-describedby']}")
        expect(hint.text.strip).to eq(I18n.t('views.users.personal_access_tokens.new.org_mode_all_hint'))
        expect(all.ancestors('label').first.text).not_to include(hint.text.strip)
      end

      it 'shows the option in the token list' do
        create(:personal_access_token, :all_organisations, user: user, name: 'Listed everywhere')
        get users_personal_access_tokens_path
        expect(response.body).to include(I18n.t('views.users.personal_access_tokens.index.scope_all_organisations'))
      end
    end

    context 'with selected_projects scope' do
      let!(:project_in_org) { project }

      let!(:project_permission) do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_permission, user: user, project: project_in_org, tickets_access: :read_only)
        end
      end

      it 'creates the token with the explicit project scope' do
        post users_personal_access_tokens_path, params: {
          current_password: user.password,
          personal_access_token: {
            name: 'Scoped',
            expires_preset: '30',
            organisation_ids: [organisation.id],
            project_mode: { organisation.id => 'selected' },
            project_ids: { organisation.id => [project_in_org.id] }
          }
        }

        token = PersonalAccessToken.find_by(name: 'Scoped')
        expect(token).to be_present
        link = token.personal_access_token_organisations.first
        expect(link.all_projects?).to be false
        ActsAsTenant.with_tenant(organisation) do
          expect(token.scoped_projects).to include(project_in_org)
        end
      end
    end

    context 'with missing organisation scope' do
      it 'rejects and re-renders new with error' do
        expect do
          post users_personal_access_tokens_path, params: {
            current_password: user.password,
            personal_access_token: {
              name: 'Bad token',
              expires_preset: '30'
            }
          }
        end.not_to change(PersonalAccessToken, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(flash.now[:alert]).to include(
          I18n.t('activerecord.errors.models.personal_access_token.no_organisation_scope')
        )
      end
    end

    context 'with an unaccessible organisation' do
      let(:foreign_org) { create(:organisation) }

      it 'silently drops the unauthorised org from the scope (validation then fails)' do
        # User is not a member of foreign_org → controller filters it out.
        expect do
          post users_personal_access_tokens_path, params: {
            current_password: user.password,
            personal_access_token: {
              name: 'Unauthorised',
              expires_preset: '30',
              organisation_ids: [foreign_org.id]
            }
          }
        end.not_to change(PersonalAccessToken, :count)
      end
    end
  end

  describe 'POST /users/personal_access_tokens (account protections)' do
    def create_token(current_password: user.password, **attrs)
      post users_personal_access_tokens_path, params: {
        current_password: current_password,
        personal_access_token: {
          name: 'Guarded', expires_preset: '30',
          organisation_ids: [organisation.id], project_mode: { organisation.id => 'all' }
        }.merge(attrs)
      }
    end

    # A token outlives the browser session it was made in, so a hijacked
    # session must not be able to mint one (the data export asks the same).
    it 'refuses without the current password' do
      expect { create_token(current_password: 'wrong-password') }.not_to change(PersonalAccessToken, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(flash.now[:alert]).to eq(I18n.t('views.users.personal_access_tokens.create.wrong_password'))
    end

    it 'creates the token with the current password' do
      expect { create_token }.to change(PersonalAccessToken, :count).by(1)
    end

    context 'with a custom expiry date' do
      it 'refuses a date beyond the maximum lifetime' do
        too_late = (PersonalAccessToken::MAX_LIFETIME + 1.day).from_now.to_date.iso8601

        expect { create_token(expires_preset: 'custom', expires_at: too_late) }
          .not_to change(PersonalAccessToken, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'accepts a date inside the maximum lifetime' do
        in_time = (PersonalAccessToken::MAX_LIFETIME - 1.day).from_now.to_date.iso8601

        expect { create_token(expires_preset: 'custom', expires_at: in_time) }
          .to change(PersonalAccessToken, :count).by(1)
      end
    end

    it 'does not link an organisation whose membership is inactive' do
      membership.update!(active: false)

      expect { create_token }.not_to change(PersonalAccessToken, :count)
    end
  end

  describe 'PATCH /users/personal_access_tokens/:id' do
    let(:pat) { create(:personal_access_token, user: user, organisations: [organisation], name: 'Old') }

    it 'updates the name' do
      patch users_personal_access_token_path(pat),
            params: { personal_access_token: { name: 'New name' } }
      expect(response).to redirect_to(users_personal_access_tokens_path)
      expect(pat.reload.name).to eq('New name')
    end

    it 'flips an existing read-only token to writable (D3)' do
      expect(pat.read_only?).to be true
      patch users_personal_access_token_path(pat),
            params: { personal_access_token: { name: pat.name, read_only: '0' } }
      expect(response).to redirect_to(users_personal_access_tokens_path)
      expect(pat.reload.read_only?).to be false
    end

    it 'returns 404 for another user’s token' do
      other_user = create(:user)
      other_pat = create(:personal_access_token, user: other_user, organisations: [organisation])
      patch users_personal_access_token_path(other_pat),
            params: { personal_access_token: { name: 'Hijack' } }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /users/personal_access_tokens/:id' do
    let!(:pat) { create(:personal_access_token, user: user, organisations: [organisation]) }

    it 'revokes the token (soft delete)' do
      expect do
        delete users_personal_access_token_path(pat)
      end.to change { pat.reload.revoked? }.from(false).to(true)

      expect(response).to redirect_to(users_personal_access_tokens_path)
    end

    it 'returns 404 for another user’s token' do
      other_user = create(:user)
      other_pat = create(:personal_access_token, user: other_user, organisations: [organisation])
      delete users_personal_access_token_path(other_pat)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'authentication' do
    it 'redirects unauthenticated users away from the index' do
      sign_out user
      get users_personal_access_tokens_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
