# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Organisation Creation', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:role, organisation: organisation) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  describe 'GET /new_organisation' do
    context 'when signed in' do
      before { sign_in user }

      it 'renders the new organisation form' do
        get new_organisation_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Neue Organisation anlegen')
      end
    end

    context 'when not signed in' do
      it 'redirects to login' do
        get new_organisation_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'POST /create_organisation' do
    context 'when signed in' do
      before { sign_in user }

      it 'creates organisation with admin role and membership' do
        expect do
          post create_organisation_path, params: { organisation: { name: 'Neue Test Org' } }
        end.to change(Organisation, :count).by(1)
                                           .and change(Membership, :count).by(1)

        new_org = Organisation.find_by(name: 'Neue Test Org')
        expect(new_org).to be_present

        ActsAsTenant.with_tenant(new_org) do
          new_membership = user.memberships.find_by(organisation: new_org)
          expect(new_membership).to be_present
          expect(new_membership.active).to be true
          expect(new_membership.role.title).to eq('account_admin')
        end
      end

      it 'redirects to the new organisation dashboard' do
        post create_organisation_path, params: { organisation: { name: 'Redirect Test Org' } }

        new_org = Organisation.find_by(name: 'Redirect Test Org')
        expect(response).to redirect_to(organisation_root_path(organisation_id: new_org.id))
      end

      context 'with blank name (HTML fallback)' do
        it 'renders the form with validation errors' do
          expect do
            post create_organisation_path, params: { organisation: { name: '' } }
          end.not_to change(Organisation, :count)

          expect(response).to have_http_status(:unprocessable_content)
        end
      end

      context 'with blank name (Turbo Stream from modal)' do
        it 'returns turbo stream with validation errors' do
          expect do
            post create_organisation_path,
                 params: { organisation: { name: '' } },
                 headers: { 'Accept' => 'text/vnd.turbo-stream.html, text/html' }
          end.not_to change(Organisation, :count)

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.media_type).to eq('text/vnd.turbo-stream.html')
          expect(response.body).to include('new_organisation_form')
        end
      end

      context 'with duplicate name' do
        let!(:existing_org) { create(:organisation, name: 'Bereits vergeben') }

        it 'renders the form with uniqueness error' do
          expect do
            post create_organisation_path, params: { organisation: { name: 'Bereits vergeben' } }
          end.not_to change(Organisation, :count)

          expect(response).to have_http_status(:unprocessable_content)
        end
      end

      context 'transaction rollback' do
        it 'does not create an organisation if membership creation fails' do
          # Raise a realistic RecordInvalid (with a record): Actors::BaseActor maps the
          # failure via e.record.errors, mirroring how Rails actually raises it.
          allow_any_instance_of(User).to receive_message_chain(:memberships, :create!)
            .and_raise(ActiveRecord::RecordInvalid.new(Membership.new))

          expect do
            post create_organisation_path, params: { organisation: { name: 'Rollback Test Org' } }
          end.not_to change(Organisation, :count)

          expect(response).to have_http_status(:unprocessable_content)
        end
      end
    end

    context 'when not signed in' do
      it 'redirects to login' do
        post create_organisation_path, params: { organisation: { name: 'Unauthorized Org' } }
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end
end
