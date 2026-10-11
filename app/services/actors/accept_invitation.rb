# frozen_string_literal: true

# app/services/actors/accept_invitation.rb
#
# Accepts an organisation invitation: validates the invitation state, registers
# the invited person if they have no account yet, marks the invitation accepted,
# and adds them to the organisation as a member.
#
# The password is ONLY used to create a new account. It never authenticates an
# existing one: an existing account is accepted solely when `current_user` is
# that very account, i.e. the invitee already signed in through Devise (with
# its lockout and throttle). Anything else fails with
# 'invitation_requires_sign_in'. Until 26.09.2026 an existing account was
# attached (and then signed in by the controller) for any password, which let
# anyone who could invite an address take over its account.
#
# #created_user? tells the caller whether THIS call registered the account; that
# is the only user a caller may sign in.

module Actors
  class AcceptInvitation < BaseActor
    def initialize(invitation:, current_user:, password: nil, password_confirmation: nil)
      super()
      @invitation = invitation
      @current_user = current_user
      @password = password
      @password_confirmation = password_confirmation
    end

    def record
      @invitation
    end

    # The account this call registered, or nil. Only meaningful after a
    # successful #call.
    attr_reader :created_user

    def created_user?
      !@created_user.nil?
    end

    def perform
      raise ActorError, 'invitation_already_accepted' if @invitation.accepted?
      raise ActorError, 'invitation_out_of_date' if @invitation.out_of_date?

      if user.nil?
        create_user
      elsif user != @current_user
        raise ActorError.new('invitation_requires_sign_in', code: :invitation_requires_sign_in)
      end
      record_terms_acceptance
      accept_invitation
      create_membership
    end

    private

    # Stamp when the terms were accepted (Art. 13 GDPR proof). Only set it when it
    # is still blank so an existing account keeps its original acceptance time; a
    # freshly created invitee gets stamped here.
    def record_terms_acceptance
      return if user.terms_accepted_at.present?

      user.update!(terms_accepted_at: Time.current)
    end

    def create_membership
      @membership = Membership.create!(
        user: @user,
        organisation: @invitation.organisation,
        active: true
      )
    end

    def accept_invitation
      @invitation.update!(accepted_at: Time.current)
    end

    # Normalised the way Devise stores addresses (case_insensitive_keys,
    # strip_whitespace_keys), so a differently cased invitation still finds the
    # existing account and cannot slip past the sign-in requirement.
    def user
      @user ||= User.find_by(email: @invitation.normalized_email)
    end

    # skip_confirmation! runs in the block, i.e. BEFORE the insert (:confirmable
    # mails from an after_create callback). The invitation token was mailed to
    # exactly this address and is being redeemed right now, so the address is
    # already proven — a second round trip would only cost the invitee a click.
    # Twin of the same decision in Users::RegistrationsController#build_resource,
    # which covers the OTHER invitation flow (signing up straight from the link).
    def create_user
      @created_user = @user = User.create!(
        email: @invitation.email,
        password: @password,
        password_confirmation: @password_confirmation,
        &:skip_confirmation!
      )
    end
  end
end
