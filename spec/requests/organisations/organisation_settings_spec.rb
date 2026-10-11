# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Organisations::OrganisationSettings', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  let!(:member_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member, organisation: organisation, role: member_role, active: true)
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
  end

  describe 'GET /org/:organisation_id/settings' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns success' do
        get organisation_settings_path(organisation)
        expect(response).to have_http_status(:success)
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'denies access and redirects' do
        get organisation_settings_path(organisation)
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
      end
    end

    context 'as unauthenticated user' do
      it 'redirects to sign in' do
        get organisation_settings_path(organisation)
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'PATCH /org/:organisation_id/settings' do
    context 'as admin' do
      before { sign_in admin }

      it 'updates the organisation and redirects' do
        patch organisation_settings_path(organisation), params: {
          organisation: { name: 'Neuer Name' }
        }
        expect(response).to redirect_to(organisation_settings_path(organisation))
        expect(organisation.reload.name).to eq('Neuer Name')
      end

      it 'renders show on validation error' do
        patch organisation_settings_path(organisation), params: {
          organisation: { name: '' }
        }
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'denies access and redirects' do
        patch organisation_settings_path(organisation), params: {
          organisation: { name: 'Hacked' }
        }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
        expect(organisation.reload.name).not_to eq('Hacked')
      end
    end
  end
end
