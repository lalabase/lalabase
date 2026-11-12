# frozen_string_literal: true

# What: the Account page as three tabs (profile, password, delete account).
# Type: Request spec.
# Why: until 2026-11-12 the three were sections of one page, the delete action a red
#   box at its foot. Each is now a page of its own under one head, and three things
#   must hold: the tab row marks the open page (aria-current), a refused form comes
#   back on the tab it was sent from (Devise re-renders :edit by default, which would
#   drop a refused password change onto the profile tab), and the delete tab only
#   explains: opening it deletes nothing, the action stays on the page behind it.
require 'rails_helper'

RSpec.describe 'Account tabs', type: :request do
  let(:user) { create(:user, password: 'secret-pass-123', password_confirmation: 'secret-pass-123') }

  before { sign_in user }

  def doc = Nokogiri::HTML(response.body)

  def tab_row
    doc.at_css("main nav[aria-label='#{I18n.t('views.devise.registrations.tabs.aria_label')}']")
  end

  def marked_tab
    tab_row.css('[aria-current="page"]').map { |tab| tab.text.squish }
  end

  def tab_label(key) = I18n.t("views.devise.registrations.tabs.#{key}")

  it 'shows three tabs on every page of the account, each marking itself' do
    { edit_user_registration_path => :profile,
      edit_user_registration_password_path => :password,
      new_account_deletion_path => :delete }.each do |path, key|
      get path

      expect(response).to have_http_status(:ok), path
      expect(tab_row.css('a, span').map { |tab| tab.text.squish })
        .to eq([tab_label(:profile), tab_label(:password), tab_label(:delete)])
      expect(marked_tab).to eq([tab_label(key)]), path
    end
  end

  it 'keeps the profile entry of the sidebar active on all three tabs' do
    [edit_user_registration_path, edit_user_registration_password_path, new_account_deletion_path].each do |path|
      get path
      entry = doc.at_css("aside a[href='#{edit_user_registration_path}']")

      expect(entry['class']).to include('sidebar-row--active'), path
    end
  end

  it 'puts the profile fields on the profile tab and the password fields on the password tab' do
    get edit_user_registration_path
    expect(doc.at_css('#user_first_name')).to be_present
    expect(doc.at_css('#user_password')).to be_nil

    get edit_user_registration_password_path
    expect(doc.at_css('#user_password')).to be_present
    expect(doc.at_css('#user_password_confirmation')).to be_present
    expect(doc.at_css('#user_current_password')).to be_present
    expect(doc.at_css('#user_first_name')).to be_nil
  end

  it 'brings a refused password change back on the password tab' do
    put user_registration_path, params: {
      account_tab: 'password',
      user: { password: 'new-pass-456', password_confirmation: 'new-pass-456', current_password: 'wrong' }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(marked_tab).to eq([tab_label(:password)])
    expect(doc.at_css('#user_password')).to be_present
    expect(user.reload.valid_password?('secret-pass-123')).to be(true)
  end

  it 'brings a refused profile change back on the profile tab' do
    put user_registration_path, params: { user: { first_name: 'Neu', current_password: 'wrong' } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(marked_tab).to eq([tab_label(:profile)])
    expect(doc.at_css('#user_first_name')).to be_present
  end

  it 'changes the password from the password tab' do
    put user_registration_path, params: {
      account_tab: 'password',
      user: { password: 'new-pass-456', password_confirmation: 'new-pass-456', current_password: 'secret-pass-123' }
    }

    expect(response).to have_http_status(:see_other)
    expect(user.reload.valid_password?('new-pass-456')).to be(true)
  end

  it 'only explains on the delete tab: opening it deletes nothing, the action is a form with a password' do
    get new_account_deletion_path

    expect(user.reload.deleted_at).to be_nil
    form = doc.at_css("main form[action='#{account_deletion_path}']")
    expect(form).to be_present
    expect(form['data-turbo-confirm']).to eq(I18n.t('account_deletion.confirm_message'))
    expect(form.at_css('input[type=password][name=current_password]')).to be_present
  end

  it 'sends a visitor without a session from the password tab to the sign-in' do
    sign_out user
    get edit_user_registration_password_path

    expect(response).to redirect_to(new_user_session_path)
  end

  it 'has no delete button on the profile tab any more, only the tab' do
    get edit_user_registration_path

    expect(doc.css("main a[href='#{new_account_deletion_path}']").size).to eq(1)
    expect(tab_row.at_css("a[href='#{new_account_deletion_path}']")).to be_present
  end
end
