# frozen_string_literal: true

require 'rails_helper'

# The invitation-acceptance page is the second GDPR collection point. It keeps its
# existing hard consent check, now backed by a real terms page, and — like
# self-registration — records an auditable acceptance timestamp on success.
RSpec.describe 'Invitation acceptance consent',
               type: :request,
               legal_identity: {
                 terms_page_url: 'https://public.example/agb',
                 privacy_page_url: 'https://public.example/datenschutz'
               } do
  let(:organisation) { create(:organisation) }
  let(:inviter) { create(:user) }
  let(:invitee_email) { 'invited.newbie@example.com' }

  let(:invitation) do
    ActsAsTenant.with_tenant(organisation) do
      create(:invitation,
             organisation: organisation,
             email: invitee_email,
             inviter: inviter,
             sent_at: 1.hour.ago)
    end
  end

  def update_path
    organisation_accept_invitation_path(organisation_id: organisation.id)
  end

  describe 'GET show' do
    it 'renders the consent checkbox linking the real terms and privacy pages' do
      get organisation_accept_invitation_path(organisation_id: organisation.id, token: invitation.token)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('https://public.example/agb')
      expect(response.body).to include('https://public.example/datenschutz')
      expect(response.body).to include('zur Kenntnis genommen')
    end

    # A self-hosted instance may set no legal URLs. The sentence still names both
    # documents, as text: a link to nowhere would be worse than none.
    it 'names terms and privacy without links when no URL is configured' do
      with_legal_identity do
        get organisation_accept_invitation_path(organisation_id: organisation.id, token: invitation.token)
      end

      label = Nokogiri::HTML(response.body).at_css('label[for="invitation_terms_accepted"]')
      expect(label.text).to include(I18n.t('views.shared.consent.terms_link_text'),
                                    I18n.t('views.shared.consent.privacy_link_text'))
      expect(label.css('a')).to be_empty
    end
  end

  describe 'PATCH update without accepting the terms' do
    it 'keeps the hard check: no user, no membership, invitation stays open' do
      invitation # create before acting
      user_count = User.count
      membership_count = Membership.count

      patch update_path, params: {
        invitation: {
          token: invitation.token,
          password: 'securePassword1!',
          password_confirmation: 'securePassword1!',
          terms_accepted: '0'
        }
      }

      expect(response).to have_http_status(:ok) # re-renders the form, does not proceed
      expect(User.count).to eq(user_count)
      expect(Membership.count).to eq(membership_count)
      expect(invitation.reload.accepted_at).to be_nil
    end
  end

  describe 'PATCH update accepting the terms' do
    it 'accepts the invitation and records the acceptance timestamp' do
      invitation

      patch update_path, params: {
        invitation: {
          token: invitation.token,
          password: 'securePassword1!',
          password_confirmation: 'securePassword1!',
          terms_accepted: '1'
        }
      }

      expect(response).to have_http_status(:redirect)
      expect(invitation.reload.accepted_at).to be_present

      user = User.find_by(email: invitee_email)
      expect(user).to be_present
      expect(user.terms_accepted_at).to be_present
      expect(Membership.exists?(user: user, organisation: organisation)).to be(true)
    end
  end

  describe 'PATCH update with the terms parameter missing' do
    # Only an explicit '1' counts as consent; an absent box is not a yes.
    it 'refuses like an unticked box' do
      invitation

      expect do
        patch update_path, params: {
          invitation: { token: invitation.token, password: 'securePassword1!', password_confirmation: 'securePassword1!' }
        }
      end.not_to change(User, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(I18n.t('flash.accept_invitations.accept_terms')))
      expect(invitation.reload.accepted_at).to be_nil
    end
  end

  describe 'PATCH update as the signed-in invitee' do
    let(:invitee) do
      create(:user, email: invitee_email, terms_accepted_at: nil)
    end

    before { sign_in invitee }

    # The consent check is not a hurdle of the new-account form only.
    it 'still requires the terms box' do
      patch update_path, params: { invitation: { token: invitation.token, terms_accepted: '0' } }

      expect(response).to have_http_status(:ok)
      expect(invitation.reload.accepted_at).to be_nil
      expect(Membership.unscoped.exists?(user_id: invitee.id, organisation_id: organisation.id)).to be(false)
    end

    it 'records the acceptance timestamp when the box is ticked' do
      patch update_path, params: { invitation: { token: invitation.token, terms_accepted: '1' } }

      expect(invitation.reload.accepted_at).to be_present
      expect(invitee.reload.terms_accepted_at).to be_present
    end
  end

  describe 'PATCH update with a token that cannot be redeemed' do
    def accept_with(token)
      patch update_path, params: {
        invitation: {
          token: token,
          password: 'securePassword1!',
          password_confirmation: 'securePassword1!',
          terms_accepted: '1'
        }
      }
    end

    it 'sends an unknown token home without creating anything' do
      expect { accept_with('no-such-token') }.not_to change(User, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq(I18n.t('flash.accept_invitations.invalid_invitation'))
    end

    it 'creates no account for an expired invitation' do
      invitation.update_column(:sent_at, (Invitation::VALIDITY + 1.minute).ago)

      expect { accept_with(invitation.token) }.not_to change(User, :count)

      expect(response).to have_http_status(:ok)
      expect(invitation.reload.accepted_at).to be_nil
    end

    # A redeemed link is spent: a second use must neither create a second
    # account nor sign anyone in.
    it 'does not accept the same token twice' do
      accept_with(invitation.token)
      expect(invitation.reload.accepted_at).to be_present
      delete destroy_user_session_path

      expect { accept_with(invitation.token) }.not_to change(User, :count)
      expect(response).to redirect_to(new_user_session_path)
      get organisation_root_path(organisation_id: organisation.id)
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
