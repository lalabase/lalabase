# frozen_string_literal: true

# app/controllers/invitations_controller.rb
class Organisations::InvitationsController < Organisations::BaseController
  before_action :authenticate_user!
  # Remove the duplicate set_organisation - it's already called in BaseController
  # before_action :set_organisation

  def new
    @invitation = Invitation.new
    @invitation.organisation = @current_organisation
    @organisation = @current_organisation  # For compatibility with the view
    authorize @invitation
  end

  def create
    @invitation = @current_organisation.invitations.build(invitation_params)
    @invitation.sent_at = Time.current
    @invitation.inviter = current_user
    @organisation = @current_organisation  # For compatibility with the view
    authorize @invitation

    if @invitation.save
      InvitationMailer.with(invitation: @invitation).invite_email.deliver_later
      redirect_to organisation_memberships_path(@current_organisation), notice: t('flash.invitations.sent')
    else
      flash.now[:alert] = t('flash.invitations.send_error')
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    @invitation = Invitation.find(params[:id])
    @organisation = @current_organisation  # For compatibility
    authorize @invitation
    @invitation.destroy
    redirect_to organisation_memberships_path(@current_organisation), notice: t('flash.invitations.deleted')
  end

  def copy_link
    @invitation = policy_scope(Invitation).find(params[:id])
    authorize @invitation
    response.headers['Cache-Control'] = 'no-store'
    render json: { url: organisation_accept_invitation_url(organisation_id: @current_organisation.id, token: @invitation.token) }
  end

  def resend
    @invitation = policy_scope(Invitation).find(params[:id])
    authorize @invitation
    @invitation.update!(sent_at: Time.current)
    InvitationMailer.with(invitation: @invitation).invite_email.deliver_later
    redirect_to organisation_memberships_path(@current_organisation), status: :see_other,
                                                                      notice: t('flash.invitations.sent')
  end

  private

  def invitation_params
    params.require(:invitation).permit(:email)
  end
end
