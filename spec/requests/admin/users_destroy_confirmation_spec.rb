# frozen_string_literal: true

require 'rails_helper'

# Request spec for the deletion confirmation in Admin::UsersController#destroy.
#
# Background: the "type the email address to confirm" gate used to exist only in the
# browser. The view declared `const requiredEmail` at the top level of an inline
# <script>; Turbo Drive re-evaluates body scripts in the same realm, so on the second
# admin user page the block died with "Identifier 'requiredEmail' has already been
# declared" -- the input listener was never bound and the delete button stayed disabled.
#
# The client side moved to a Stimulus controller, and the gate itself moved here: the
# server now rejects a DELETE whose email_confirmation does not match. These examples
# pin that the check exists at all (it did not before) and that its comparison rule
# stays forgiving about whitespace and casing, matching
# app/javascript/controllers/admin_user_delete_modal_controller.js.
RSpec.describe 'Admin::Users#destroy email confirmation', type: :request do
  let(:admin_beuser) { create(:beuser) }
  let!(:user) { create(:user, email: 'jdoe@example.com') }

  before do
    post admin_log_in_path, params: { email: admin_beuser.email, password: admin_beuser.password }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  def deleted?
    ::User.find_with_deleted(user.id).deleted_at.present?
  rescue ActiveRecord::RecordNotFound
    true
  end

  context 'when the confirmation does not match' do
    it 'refuses a wrong email and keeps the account' do
      delete admin_user_path(user), params: { email_confirmation: 'someone.else@example.com' }

      expect(response).to redirect_to(admin_user_path(user))
      expect(flash[:alert]).to eq(I18n.t('flash.admin.users.email_confirmation_mismatch'))
      expect(deleted?).to be(false)
    end

    it 'refuses a missing confirmation param and keeps the account' do
      delete admin_user_path(user)

      expect(response).to redirect_to(admin_user_path(user))
      expect(deleted?).to be(false)
    end

    it 'refuses a blank confirmation and keeps the account' do
      delete admin_user_path(user), params: { email_confirmation: '   ' }

      expect(response).to redirect_to(admin_user_path(user))
      expect(deleted?).to be(false)
    end

    # A blank stored email must not turn into a free pass via "'' == ''".
    it 'refuses a blank confirmation even when the stored email is blank' do
      user.update_columns(email: '')

      delete admin_user_path(user), params: { email_confirmation: '' }

      expect(response).to redirect_to(admin_user_path(user))
      expect(deleted?).to be(false)
    end
  end

  context 'when the confirmation matches' do
    it 'deletes the account on an exact match' do
      delete admin_user_path(user), params: { email_confirmation: 'jdoe@example.com' }

      expect(response).to redirect_to(admin_users_path)
      expect(deleted?).to be(true)
    end

    it 'tolerates surrounding whitespace and casing, like the Stimulus controller does' do
      delete admin_user_path(user), params: { email_confirmation: "  JDoe@Example.COM \n" }

      expect(response).to redirect_to(admin_users_path)
      expect(deleted?).to be(true)
    end
  end
end
