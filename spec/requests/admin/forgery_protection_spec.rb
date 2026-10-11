# frozen_string_literal: true

require 'rails_helper'

# The admin area must REJECT a write without an authenticity token. Under the
# :null_session strategy the forged request only lost its session, but the
# admin login runs before the token check and had already cached the beuser,
# so the action still ran as that admin. :exception, prepended, refuses the
# request before anything else happens. The refusal is a redirect with a
# message instead of Rails' bare 422 page: a stale admin tab (a sign-in to the
# app in the same browser rotates the token) must tell the admin what happened.
#
# Request specs run with forgery protection off; it is switched on here. Every
# refusal has a control that sends the same request WITH the page's token and
# goes through, so the refusal cannot come from anything but the token.
RSpec.describe 'Admin area: forgery protection', type: :request do
  let(:beuser) { create(:beuser) } # factory: role 'admin', active

  around do |example|
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  # With protection on, the login form itself needs the token.
  before do
    get admin_log_in_path
    post admin_log_in_path, params: { email: beuser.email, password: beuser.password,
                                      authenticity_token: token_from(response.body) }
    expect(response).to redirect_to(admin_dashboard_path)
  end

  def token_from(html)
    Nokogiri::HTML(html).at('input[name="authenticity_token"]')&.[]('value') ||
      Nokogiri::HTML(html).at('meta[name="csrf-token"]')&.[]('content')
  end

  let(:new_admin_params) do
    { beuser: { role: 'admin', active: '1', firstname: 'New', lastname: 'Admin',
                email: 'forged-admin@example.com', password: 'a-long-password',
                password_confirmation: 'a-long-password' } }
  end

  it 'refuses to create a beuser without a token' do
    expect { post admin_beusers_path, params: new_admin_params }.not_to change(Beuser, :count)

    expect(response).to redirect_to(admin_dashboard_path)
    expect(flash[:alert]).to eq(I18n.t('flash.admin.forgery.stale_form'))
  end

  it 'sends a stale login form back to the login page with a message' do
    reset! # a fresh browser: no admin session, no token

    post admin_log_in_path, params: { email: beuser.email, password: beuser.password }

    expect(response).to redirect_to(admin_log_in_path)
    expect(flash[:alert]).to eq(I18n.t('flash.admin.forgery.stale_form'))
  end

  it 'creates the beuser with the token of the form' do
    get new_admin_beuser_path

    expect { post admin_beusers_path, params: new_admin_params.merge(authenticity_token: token_from(response.body)) }
      .to change(Beuser, :count).by(1)
  end

  # Mission Control inherits the admin base controller, so it inherits the
  # strategy too. Retrying a job that does not exist is enough: the token check
  # answers before the engine looks the job up.
  describe 'Mission Control' do
    def retry_path
      "/admin/jobs/applications/#{MissionControl::Jobs.applications.first.id}/jobs/missing/retry"
    end

    it 'refuses a write without a token' do
      post retry_path

      # After a request into the engine the bare helper resolves inside it.
      expect(response).to redirect_to(Rails.application.routes.url_helpers.admin_dashboard_path)
      expect(flash[:alert]).to eq(I18n.t('flash.admin.forgery.stale_form'))
    end

    it 'passes the token check with the token of a page' do
      get admin_dashboard_path

      post retry_path, params: { authenticity_token: token_from(response.body) }

      expect(flash[:alert]).not_to eq(I18n.t('flash.admin.forgery.stale_form'))
    end
  end
end
