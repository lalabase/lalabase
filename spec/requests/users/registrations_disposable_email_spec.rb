# frozen_string_literal: true

require 'rails_helper'

# Throw-away addresses on the self-service sign-up (doc/bot_registrierungen_plan.md S2).
# The asymmetry is the point: the rule holds on the open path and must NOT hold
# on the invitation path, where the address was chosen by us, not by the visitor.
RSpec.describe 'Sign-up with a throw-away address', type: :request do
  before { User.system }

  def signup_params(email:)
    {
      user: {
        first_name: 'Otto', last_name: 'Neuling',
        email: email, password: 'password123',
        password_confirmation: 'password123', terms_accepted: '1'
      }
    }.merge(bot_trap_params)
  end

  it 'rejects a listed domain without writing anything' do
    expect { post user_registration_path, params: signup_params(email: 'otto@mailinator.com') }
      .not_to change(User, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t('flash.registrations.disposable_email'))
  end

  # Uppercase is the cheapest bypass there is; without this pin, dropping the
  # .downcase in DisposableEmailDomains.match? keeps every spec green.
  it 'rejects a listed domain regardless of case' do
    post user_registration_path, params: signup_params(email: 'otto@MAILINATOR.COM')

    expect(response).to have_http_status(:unprocessable_content)
  end

  # Listing every subdomain of every service is a race nobody wins, so the check
  # covers them. A spec on the top-level domain alone would pass with that rule
  # removed.
  it 'rejects a subdomain of a listed domain' do
    post user_registration_path, params: signup_params(email: 'otto@mail.mailinator.com')

    expect(response).to have_http_status(:unprocessable_content)
  end

  # A trailing-dot FQDN ("mailinator.com.") is the same mailbox but slips the
  # naive == / end_with? comparison; without the chomp it registers freely.
  it 'rejects a listed domain written as a root-anchored FQDN' do
    post user_registration_path, params: signup_params(email: 'otto@mailinator.com.')

    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'lets a normal address through' do
    expect { post user_registration_path, params: signup_params(email: 'otto@musterfirma.de') }
      .to change(User, :count).by(1)
  end

  # A domain that merely ENDS in a listed one is a different domain:
  # "nichtmailinator.com" is not "mailinator.com".
  it 'does not reject a domain that only ends in a listed name' do
    expect { post user_registration_path, params: signup_params(email: 'otto@nichtmailinator.com') }
      .to change(User, :count).by(1)
  end

  it 'accepts an invited person even on a listed domain' do
    organisation = create(:organisation)
    invitation = ActsAsTenant.with_tenant(organisation) do
      create(:invitation, organisation: organisation, email: 'kollege@mailinator.com')
    end

    params = signup_params(email: 'kollege@mailinator.com').merge(token: invitation.token)

    expect { post user_registration_path, params: params }.to change(User, :count).by(1)
  end

  # The bypass is keyed on a REDEEMABLE invitation (valid_invitation), not merely
  # a token being present. An expired invitation on a listed domain must still be
  # rejected -- otherwise the mutation !valid_invitation -> !@invitation (any
  # token bypasses the filter) stays green across the whole suite.
  it 'rejects a listed domain when the invitation is expired' do
    organisation = create(:organisation)
    invitation = ActsAsTenant.with_tenant(organisation) do
      create(:invitation, organisation: organisation, email: 'kollege@mailinator.com', sent_at: 1.month.ago)
    end

    params = signup_params(email: 'kollege@mailinator.com').merge(token: invitation.token)

    expect { post user_registration_path, params: params }.not_to change(User, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  # Degenerate input reaches match? before any format validation runs; it must
  # answer false, never raise.
  it 'treats blank or at-less input as not disposable' do
    expect(DisposableEmailDomains.match?(nil)).to be(false)
    expect(DisposableEmailDomains.match?('')).to be(false)
    expect(DisposableEmailDomains.match?('no-at-sign')).to be(false)
  end
end
