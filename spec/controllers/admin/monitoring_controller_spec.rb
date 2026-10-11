# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::MonitoringController, type: :controller do
  # Admin current_user is a Beuser, not a User -- require_login now re-checks
  # admin? && active on every request (D4/D8), so the stub must be an admin beuser.
  let(:admin_beuser) { create(:beuser, role: 'admin', active: true) }
  let(:deploy_time) { Time.zone.parse('2025-09-29 12:00:00') }

  before do
    routes.draw do
      namespace :admin do
        get 'monitoring', to: 'monitoring#index'
        get 'log_in', to: 'sessions#new'
      end
    end

    @request.env['devise.mapping'] = Devise.mappings[:user]
    allow(controller).to receive(:current_user).and_return(admin_beuser)
  end

  it 'renders deployment information' do
    allow_any_instance_of(described_class).to receive(:detect_commit_hash).and_return('abc123')
    allow_any_instance_of(described_class).to receive(:detect_last_deployed_at).and_return(deploy_time)

    get :index

    expect(response).to be_successful
    expect(assigns(:commit_hash)).to eq('abc123')
    expect(assigns(:last_deployed_at)).to eq(deploy_time)
    expect(response).to render_template(:index)
  end
end
