# frozen_string_literal: true

# app/controllers/organisations/accept_invitations_controller.rb
module Organisations
  class AcceptInvitationsController < Organisations::BaseController
    skip_before_action :authenticate_user!
    skip_before_action :set_organisation
    skip_before_action :set_current_membership
    skip_before_action :load_tenant_from_session
    skip_before_action :ensure_items_parameter
    skip_after_action :verify_authorized, raise: false
    skip_after_action :verify_policy_scoped, raise: false

    # Four cases, one rule: sign_in only ever happens for a user THIS request
    # created. An existing account accepts only while signed in as exactly that
    # account (see Actors::AcceptInvitation, which enforces the same rule itself).
    def show
      find_invitation(params[:token])
      return unless @invitation

      prepare_acceptance(refusal_status: :ok)
    end

    def update
      find_invitation(accept_invitation_params[:token])
      return unless @invitation
      return unless prepare_acceptance(refusal_status: :forbidden)

      @invitation.terms_accepted = accept_invitation_params[:terms_accepted]
      unless @invitation.terms_accepted == '1'
        flash.now[:alert] = t('flash.accept_invitations.accept_terms')
        return render :show
      end

      ActsAsTenant.with_tenant(@invitation.organisation) do
        actor = Actors::AcceptInvitation.new(invitation: @invitation,
                                             current_user: current_user,
                                             **password_params)
        result = actor.call

        if result.success?
          sign_in(actor.created_user) if actor.created_user?
          redirect_to organisation_root_path(organisation_id: @invitation.organisation_id),
                      notice: t('flash.accept_invitations.accepted')
        else
          flash.now[:alert] = result.errors.join(', ')
          render :show
        end
      end
    end

    private

    def find_invitation(token)
      ActsAsTenant.without_tenant do
        @invitation = Invitation.find_by(token: token)
      end
      return if @invitation

      redirect_to root_path, notice: t('flash.accept_invitations.invalid_invitation')
    end

    # Sorts the request into one of the acceptance modes and handles the two
    # that end here. Returns true when the form may be shown or submitted.
    #   :create_account   no account for the address yet, nobody signed in
    #   :accept_signed_in signed in as the invited account, terms box only
    #   :wrong_account    signed in as someone else: refused, nothing changes
    # An existing account without a session is sent to the Devise sign-in and
    # comes back here afterwards (DEEP_LINK_AFTER_SIGN_IN).
    def prepare_acceptance(refusal_status:)
      @acceptance_mode =
        if user_signed_in?
          invited_address?(current_user.email) ? :accept_signed_in : :wrong_account
        elsif invitee_account_exists?
          store_location_for(:user, organisation_accept_invitation_path(organisation_id: @invitation.organisation_id,
                                                                        token: @invitation.token))
          redirect_to new_user_session_path, alert: t('flash.accept_invitations.sign_in_required')
          return false
        else
          :create_account
        end

      return true unless @acceptance_mode == :wrong_account

      flash.now[:alert] = t('flash.accept_invitations.wrong_account')
      render :show, status: refusal_status
      false
    end

    def invited_address?(email)
      @invitation.addressed_to?(email)
    end

    def invitee_account_exists?
      User.exists?(email: @invitation.normalized_email)
    end

    # Only a new account takes a password; a signed-in invitee sends none.
    def password_params
      return {} unless @acceptance_mode == :create_account

      accept_invitation_params.slice(:password, :password_confirmation).to_h.symbolize_keys
    end

    def accept_invitation_params
      params.require(:invitation).permit(:password, :password_confirmation, :terms_accepted, :token)
    end
  end
end
