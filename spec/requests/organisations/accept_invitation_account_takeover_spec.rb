# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the account takeover found on 26.09.2026: the acceptance
# endpoint runs without authentication and used to sign in whichever account
# matched the invitation address, without ever checking that account's password.
# Anyone could register, invite a victim, copy the link and PATCH it with any
# password to end up signed in as the victim.
#
# The rule now: sign_in only ever happens for a user THIS request created. An
# existing account accepts only while signed in as exactly that account; the
# password is never checked here (no lockable, no throttle on this door).
RSpec.describe 'Invitation acceptance: account ownership', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:inviter) { create(:user) }

  # The victim has an organisation of their own, so a protected page exists that
  # only a signed-in victim can open (and that proves the negative below).
  let(:victim_organisation) { create(:organisation) }
  let!(:victim) do
    create(:user, email: 'victim@example.com', password: 'victimsOwnPass1!').tap do |user|
      ActsAsTenant.with_tenant(victim_organisation) do
        create(:membership, user: user, organisation: victim_organisation)
      end
    end
  end

  def invite(email)
    ActsAsTenant.with_tenant(organisation) do
      create(:invitation, organisation: organisation, email: email, inviter: inviter, sent_at: 1.hour.ago)
    end
  end

  def accept(invitation, password: 'attackerPicked1!')
    patch organisation_accept_invitation_path(organisation_id: organisation.id), params: {
      invitation: {
        token: invitation.token,
        password: password,
        password_confirmation: password,
        terms_accepted: '1'
      }
    }
  end

  def invitation_path_for(invitation)
    organisation_accept_invitation_path(organisation_id: organisation.id, token: invitation.token)
  end

  def victim_home
    organisation_root_path(organisation_id: victim_organisation.id)
  end

  def member?(user)
    Membership.unscoped.exists?(user_id: user.id, organisation_id: organisation.id)
  end

  # Positive counterproof for every "not signed in" below: the same protected
  # page DOES answer a genuinely signed-in victim, so a redirect there means
  # something.
  it 'serves the protected page to the signed-in victim (counterproof)' do
    sign_in victim
    get victim_home

    expect(response).to have_http_status(:ok)
  end

  context 'when the address belongs to an existing account and nobody is signed in' do
    let(:invitation) { invite(victim.email) }

    it 'does not sign anyone in, adds no membership and leaves the invitation open' do
      accept(invitation)

      expect(member?(victim)).to be(false)
      expect(invitation.reload.accepted_at).to be_nil
      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('flash.accept_invitations.sign_in_required'))

      get victim_home
      expect(response).to redirect_to(new_user_session_path)
    end

    it 'matches the address regardless of case' do
      invitation = invite('Victim@Example.com')

      accept(invitation)

      # The controller must recognise the account too, not merely lean on the
      # actor: otherwise the invitee gets a raw error instead of the sign-in.
      expect(response).to redirect_to(new_user_session_path)
      get victim_home
      expect(response).to redirect_to(new_user_session_path)
      expect(member?(victim)).to be(false)
      expect(User.where('LOWER(email) = ?', 'victim@example.com').count).to eq(1)
    end

    # Knowing the real password changes nothing: this page never checks it.
    it 'does not accept even with the account owner\'s correct password' do
      accept(invitation, password: 'victimsOwnPass1!')

      expect(member?(victim)).to be(false)
      expect(invitation.reload.accepted_at).to be_nil
      expect(response).to redirect_to(new_user_session_path)
      get victim_home
      expect(response).to redirect_to(new_user_session_path)
    end

    it 'sends the invitee to the sign-in page from the invitation link' do
      get invitation_path_for(invitation)

      expect(response).to redirect_to(new_user_session_path)
      expect(flash[:alert]).to eq(I18n.t('flash.accept_invitations.sign_in_required'))
    end

    it 'brings the invitee back to the invitation after signing in' do
      get invitation_path_for(invitation)
      expect(response).to redirect_to(new_user_session_path)

      post user_session_path, params: { user: { email: victim.email, password: 'victimsOwnPass1!' } }

      # The victim HAS organisations, which is exactly the case where
      # after_sign_in_path_for used to drop the stored location.
      expect(response).to redirect_to(invitation_path_for(invitation))

      follow_redirect!
      expect(response).to have_http_status(:ok)
      form = Nokogiri::HTML(response.body).at_css('form[action*="accept_invitation"]')
      expect(form).to be_present
      expect(form.at_css('input[type="password"]')).to be_nil
    end
  end

  context 'when signed in as the invited account' do
    let(:invitation) { invite('VICTIM@example.com') }

    before { sign_in victim }

    it 'shows an accept form without password fields' do
      get invitation_path_for(invitation)

      expect(response).to have_http_status(:ok)
      form = Nokogiri::HTML(response.body).at_css('form[action*="accept_invitation"]')
      expect(form).to be_present
      expect(form.at_css('input[name="invitation[terms_accepted]"]')).to be_present
      expect(form.at_css('input[type="password"]')).to be_nil
    end

    it 'accepts with the terms box alone and adds the membership' do
      patch organisation_accept_invitation_path(organisation_id: organisation.id), params: {
        invitation: { token: invitation.token, terms_accepted: '1' }
      }

      expect(response).to redirect_to(organisation_root_path(organisation_id: organisation.id))
      expect(invitation.reload.accepted_at).to be_present
      expect(member?(victim)).to be(true)
    end
  end

  context 'when signed in as a different account' do
    let(:invitation) { invite(victim.email) }
    let(:attacker) { create(:user, email: 'attacker@example.com') }

    before { sign_in attacker }

    it 'rejects the acceptance and changes nothing' do
      accept(invitation)

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include(CGI.escapeHTML(I18n.t('flash.accept_invitations.wrong_account')))
      expect(invitation.reload.accepted_at).to be_nil
      expect(member?(victim)).to be(false)
      expect(member?(attacker)).to be(false)

      # Still the attacker, not the victim.
      get victim_home
      expect(response).not_to have_http_status(:ok)
    end

    it 'shows no accept form on the invitation page' do
      get invitation_path_for(invitation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(I18n.t('flash.accept_invitations.wrong_account')))
      expect(Nokogiri::HTML(response.body).at_css('form[action*="accept_invitation"]')).to be_nil
    end
  end

  # A session never switches accounts silently, not even to a brand-new one.
  context 'when signed in as another account and the address has no account yet' do
    let(:invitation) { invite('brand.new@example.com') }
    let(:attacker_organisation) { create(:organisation) }
    let(:attacker) do
      create(:user, email: 'attacker@example.com').tap do |user|
        ActsAsTenant.with_tenant(attacker_organisation) do
          create(:membership, user: user, organisation: attacker_organisation)
        end
      end
    end

    before { sign_in attacker }

    it 'refuses, creates no account and keeps the current session' do
      invitation
      expect { accept(invitation) }.not_to change(User, :count)

      expect(response).to have_http_status(:forbidden)
      expect(invitation.reload.accepted_at).to be_nil

      get organisation_root_path(organisation_id: attacker_organisation.id)
      expect(response).to have_http_status(:ok)
    end
  end

  context 'when the address has no account yet' do
    let(:invitation) { invite('brand.new@example.com') }

    it 'creates the account, accepts and signs the new user in (unchanged)' do
      invitation
      expect { accept(invitation, password: 'newUsersPass1!') }.to change(User, :count).by(1)

      new_user = User.find_by(email: 'brand.new@example.com')
      expect(response).to redirect_to(organisation_root_path(organisation_id: organisation.id))
      expect(invitation.reload.accepted_at).to be_present
      expect(member?(new_user)).to be(true)

      get organisation_root_path(organisation_id: organisation.id)
      expect(response).to have_http_status(:ok)
    end

    it 'still shows the password fields' do
      get invitation_path_for(invitation)

      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).css('input[type="password"]').size).to eq(2)
    end
  end

  # The controller's own rule, isolated from the actor's: whatever the actor
  # reports as success, only the user it CREATED may be signed in. Simulates an
  # account appearing between the controller's check and the actor (a race), or
  # an actor regression; a sign-in by address would then hand out that account.
  describe 'sign_in only for the user the actor created' do
    let(:invitation) { invite('racer@example.com') }

    it 'signs nobody in when the actor created no user' do
      invitation
      racer_organisation = create(:organisation)
      fake_actor = instance_double(Actors::AcceptInvitation, created_user?: false, created_user: nil)
      allow(fake_actor).to receive(:call) do
        racer = create(:user, email: 'racer@example.com')
        ActsAsTenant.with_tenant(racer_organisation) do
          create(:membership, user: racer, organisation: racer_organisation)
        end
        Actors::BaseActor::Result.new(success: true, resource: invitation)
      end
      allow(Actors::AcceptInvitation).to receive(:new).and_return(fake_actor)

      accept(invitation)
      expect(response).to redirect_to(organisation_root_path(organisation_id: organisation.id))

      get organisation_root_path(organisation_id: racer_organisation.id)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'DEEP_LINK_AFTER_SIGN_IN' do
    let(:pattern) { ApplicationController::DEEP_LINK_AFTER_SIGN_IN }

    it 'keeps the invitation page, with and without its token' do
      expect(pattern).to match('/org/abc/accept_invitation?token=xyz')
      expect(pattern).to match('/org/abc/accept_invitation')
    end

    it 'keeps nothing that merely starts like the invitation page' do
      expect(pattern).not_to match('/org/abc/accept_invitation/success')
      expect(pattern).not_to match('/org/abc/accept_invitations')
      expect(pattern).not_to match('/evil/org/abc/accept_invitation')
    end
  end
end
