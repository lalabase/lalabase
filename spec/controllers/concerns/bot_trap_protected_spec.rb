# frozen_string_literal: true

require 'rails_helper'

# The concern ships two DEFAULT responses for the next public form that includes
# it (password reset, contact form): a filled honeypot gets a silent 303 to
# root, a missing/late timestamp gets a visible redirect-back with a neutral
# alert. Users::RegistrationsController overrides both, so the request spec pins
# only the overrides -- the defaults would otherwise reach production for the
# first time on an endpoint that has no spec of its own.
RSpec.describe BotTrapProtected, type: :controller do
  # Anonymous controller on ActionController::Base to exercise the concern in
  # isolation, without ApplicationController's auth/tenant before_actions.
  controller(ActionController::Base) do
    include BotTrapProtected
    protect_from_bots only: :create

    def create
      render plain: 'real success'
    end
  end

  before do
    routes.draw do
      post 'anonymous' => 'anonymous#create'
      root to: 'anonymous#create'
    end
  end

  it 'answers a filled honeypot with a silent 303 to root (default pretend-success)' do
    post :create, params: { BotTrapProtected::HONEYPOT_FIELD => 'http://spam.example' }

    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to('/')
  end

  it 'answers a missing timestamp with a redirect back and the neutral alert (default reject)' do
    request.env['HTTP_REFERER'] = '/somewhere'

    post :create

    expect(response).to redirect_to('/somewhere')
    expect(flash[:alert]).to eq(I18n.t('flash.bot_trap.rejected'))
  end

  it 'lets a well-timed submission with an empty honeypot reach the action' do
    timestamp = Rails.application.message_verifier(BotTrapProtected::VERIFIER_SALT)
                     .generate(10.seconds.ago.to_i, purpose: BotTrapProtected::VERIFIER_PURPOSE)

    post :create, params: { BotTrapProtected::TIMESTAMP_FIELD => timestamp }

    expect(response.body).to eq('real success')
  end
end
