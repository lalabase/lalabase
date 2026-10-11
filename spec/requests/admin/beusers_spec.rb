# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin: beusers', type: :request do
  let(:beuser) { create(:beuser) } # factory: role 'admin', active

  before do
    post admin_log_in_path, params: { email: beuser.email, password: beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  describe 'DELETE /admin/beusers/:id' do
    # The id is the same row in any letter case; the old guard compared the raw
    # param as a string and only held for the lowercase spelling.
    it 'refuses to delete the signed-in beuser, whatever the case of the id' do
      expect { delete admin_beuser_path(beuser.id.upcase) }.not_to change(Beuser, :count)

      expect(response).to redirect_to(admin_beusers_path)
      expect(flash[:alert]).to eq(I18n.t('flash.admin.beusers.cannot_delete_self'))
    end

    it 'deletes another beuser' do
      other = create(:beuser)

      expect { delete admin_beuser_path(other) }.to change(Beuser, :count).by(-1)
      expect(response).to redirect_to(admin_beusers_path)
    end
  end

  describe 'POST /admin/beusers/:id/update_password' do
    it 'refuses a password below the Devise floor' do
      short = 'x' * (Devise.password_length.min - 1)
      original = beuser.password

      post update_password_admin_beuser_path(beuser),
           params: { beuser: { password: short, password_confirmation: short } }

      expect(beuser.reload.authenticate(short)).to be(false)
      expect(beuser.authenticate(original)).to be_truthy
      # Turbo drops a 200 answer to a form submission; only 422 shows the error.
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'POST /admin/beusers' do
    it 'refuses a password below the Devise floor with a form Turbo renders' do
      short = 'x' * (Devise.password_length.min - 1)

      expect do
        post admin_beusers_path, params: { beuser: { role: 'admin', active: '1', email: 'short@example.com',
                                                     password: short, password_confirmation: short } }
      end.not_to change(Beuser, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'PATCH /admin/beusers/:id' do
    it 'refuses to demote the last active admin and says why' do
      patch admin_beuser_path(beuser), params: { beuser: { role: 'user' } }

      expect(beuser.reload.role).to eq('admin')
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(CGI.escapeHTML(I18n.t('activerecord.errors.models.beuser.last_active_admin')))
    end

    it 'demotes an admin while another active admin remains' do
      other = create(:beuser)

      patch admin_beuser_path(other), params: { beuser: { role: 'user' } }

      expect(other.reload.role).to eq('user')
      expect(response).to redirect_to(admin_beusers_path)
    end
  end

  describe 'an unknown id' do
    let(:unknown) { SecureRandom.uuid }

    it 'answers 404 on every member action' do
      get edit_admin_beuser_path(unknown)
      expect(response).to have_http_status(:not_found)

      patch admin_beuser_path(unknown), params: { beuser: { firstname: 'X' } }
      expect(response).to have_http_status(:not_found)

      get edit_password_admin_beuser_path(unknown)
      expect(response).to have_http_status(:not_found)

      post update_password_admin_beuser_path(unknown), params: { beuser: { password: 'x', password_confirmation: 'x' } }
      expect(response).to have_http_status(:not_found)
    end
  end
end
