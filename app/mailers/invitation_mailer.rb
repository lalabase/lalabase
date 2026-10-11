# frozen_string_literal: true

# app/mailers/invitation_mailer.rb
class InvitationMailer < ApplicationMailer
  def invite_email
    @invitation = params[:invitation]
    @organisation = @invitation.organisation
    @user = @invitation.inviter
    @url = organisation_accept_invitation_url(organisation_id: @invitation.organisation_id, token: @invitation.token)
    mail(to: @invitation.email, subject: I18n.t('invitation_mailer.invite_email.subject'))
  end
end
