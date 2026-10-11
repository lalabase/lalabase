# frozen_string_literal: true

# app/controllers/users/registrations_controller.rb
module Users
  class RegistrationsController < Devise::RegistrationsController
    layout :determine_layout

    # The flash each domain refusal of Actors::CreateSignup gets on the form.
    SIGNUP_REJECTIONS = {
      terms_not_accepted: 'flash.registrations.accept_terms',
      disposable_email: 'flash.registrations.disposable_email',
      organisation_creation_failed: 'flash.registrations.organisation_creation_failed'
    }.freeze

    # The app-wide default (default_protect_from_forgery) is already :exception;
    # this line restates it on purpose. Registration needs no session, so a :null_session strategy here
    # would let a forged cross-site POST still create accounts. Keeping the
    # strategy explicit means a change to the app-wide default cannot weaken
    # this controller (pinned by
    # spec/requests/users/registrations_onboarding_spec.rb).
    protect_from_forgery with: :exception
    include BotTrapProtected
    skip_before_action :load_tenant_from_session
    before_action :configure_permitted_parameters, if: :devise_controller?

    # The form asks the same question build_resource does: with a redeemable
    # invitation the address is fixed, so the page shows it instead of an input.
    helper_method :valid_invitation

    # Registration-closed check runs BEFORE the bot trap: otherwise a closed
    # instance still answers the honeypot with a fake "welcome, you registered"
    # and answers a bad timestamp with the full sign-up form in the body -- a
    # form #new never renders when registration is off. Declared ahead of
    # protect_from_bots so this before_action fires first.
    before_action :ensure_registration_allowed, only: :create

    # Honeypot + signed render timestamp. Only on create -- #new has no
    # submission to judge, and the fields are rendered there.
    protect_from_bots only: :create

    def new
      # Disable ActsAsTenant for registration
      ActsAsTenant.without_tenant do
        @invitation = invitation_from_token

        # Check whether registrations are allowed (invitations are always allowed)
        unless SystemSetting.allow_registration? || @invitation
          @registration_disabled_message = SystemSetting.registration_disabled_message
          render 'registration_disabled', layout: 'application_auth' and return
        end

        # Self-registration lives on a separate website for this instance
        # (website split, W4). Off unless LALABASE_SIGNUP_URL is set, so a
        # self-hosted instance keeps serving this form.
        #
        # An INVITED guest stays here whatever is configured: the website form
        # cannot redeem a token, so sending them there would quietly create a
        # NEW organisation instead of joining the one that invited them.
        #
        # 302, not 301: a permanent redirect outlives unsetting the variable,
        # and rolling the switch back is the whole fallback plan.
        #
        # #create is deliberately NOT redirected. A form already open in
        # someone else tab must still submit rather than lose what they
        # typed, and it reaches the same actor the website calls.
        if @invitation.nil? && signup_hosted_elsewhere?
          redirect_to hosted_signup_url, allow_other_host: true, status: :found
          return
        end

        # An invitation prefills the invited address in #build_resource.
        super
      end
    end

    def create
      # Disable ActsAsTenant for registration
      ActsAsTenant.without_tenant do
        # Registration-closed is already enforced by ensure_registration_allowed
        # (before the bot trap); @invitation is set there and reused here.
        @invitation = invitation_from_token
        next create_self_signup unless valid_invitation

        # --- Invitation ------------------------------------------------------
        # Joins the inviting organisation: no own organisation, no onboarding
        # seed, no acquisition source, no confirmation mail
        # (see build_resource). Stays here until invitations get their own actor.

        # Enforce the terms/privacy consent checkbox server-side.
        reject_signup('flash.registrations.accept_terms') and return unless terms_accepted?

        super do |resource|
          next unless resource.persisted?

          # Record the point in time the terms were accepted (Art. 13 GDPR proof)
          resource.update!(terms_accepted_at: Time.current)

          organisation = valid_invitation.organisation
          resource.organisations << organisation
          valid_invitation.update(accepted_at: Time.current)
          resource.track_invitation_accepted(organisation: organisation)
          resource.track_registration(request: request, organisation: organisation)
        end
      end
    end

    # DELETE /users. Devise's own action destroyed the row at once: no password,
    # no grace period, no deletion log. Account deletion has one door, the
    # AccountDeletionsController with DeleteAccountService behind it.
    def destroy
      redirect_to new_account_deletion_path
    end

    private

    # --- Self-registration (Actors::CreateSignup) ----------------------------
    # The actor decides and writes; this controller keeps what belongs to the web
    # form: the param shapes, the session's acquisition source, the flash, the
    # Devise sign-in and the redirect. The provisioning endpoint for the separate
    # website calls the same actor (website split, step W2).

    def create_self_signup
      signup = Actors::CreateSignup.new(**self_signup_arguments)
      result = signup.call
      return respond_to_failed_signup(result) unless result.success?

      # The source belongs to the account now; left behind, it would attach the
      # same origin to a second account created from the same browser.
      forget_acquisition_source
      respond_to_signup(result.resource)
    end

    def self_signup_arguments
      form = sign_up_params
      {
        email: form[:email], password: form[:password], password_confirmation: form[:password_confirmation],
        first_name: form[:first_name], last_name: form[:last_name],
        language: I18n.locale.to_s, terms_accepted: terms_accepted? == true,
        organisation_name: user_form_scalar(:organisation_name),
        acquisition: stored_acquisition_source,
        request: request
      }
    end

    # Twin of the persisted branch of Devise::RegistrationsController#create, which
    # cannot be reused because it saves the resource itself. Keep the two in step
    # when Devise changes: the bot trap's pretend success is compared against this
    # response (spec/requests/users/bot_trap_spec.rb).
    def respond_to_signup(user)
      self.resource = user
      if resource.active_for_authentication?
        set_flash_message! :notice, :signed_up
        sign_up(resource_name, resource)
        respond_with resource, location: after_sign_up_path_for(resource)
      else
        set_flash_message! :notice, :"signed_up_but_#{resource.inactive_message}"
        expire_data_after_sign_in!
        respond_with resource, location: after_inactive_sign_up_path_for(resource)
      end
    end

    def respond_to_failed_signup(result)
      case result.code
      when *SIGNUP_REJECTIONS.keys
        reject_signup(SIGNUP_REJECTIONS.fetch(result.code))
      when :validation_failed
        # Twin of the failed branch of Devise's #create: the unsaved user carries
        # the errors the form shows.
        self.resource = result.resource
        clean_up_passwords(resource)
        set_minimum_password_length
        respond_with resource
      when :registration_closed
        flash[:alert] = SystemSetting.registration_disabled_message
        redirect_to new_user_registration_path
      else
        raise "Registration failed (#{result.code}): #{result.errors.join(', ')}"
      end
    end

    # --- Bot trap (BotTrapProtected) -----------------------------------------
    # Both branches deliberately differ; the reasoning is in the concern.

    # Imitates the page a real sign-up produces, down to the flash. Anything
    # else (a blank page, a different notice) tells the sender that this address
    # tripped something.
    #
    # WHICH of Devise's two messages applies is DERIVED, not copied: with a
    # grace period the fresh account is active_for_authentication? and Devise
    # says :signed_up, without one it says :signed_up_but_unconfirmed. Hard-
    # coding one would start lying the day allow_unconfirmed_access_for changes,
    # and lying is the whole failure mode here. Pinned by the bot-trap spec,
    # which compares this response against a REAL registration rather than
    # against a second copy of this rule.
    def bot_trap_pretend_success
      grace_period = User.allow_unconfirmed_access_for.to_i.positive?
      set_flash_message! :notice, grace_period ? :signed_up : :signed_up_but_unconfirmed
      # Status AND target mimic the real thing (both were working bot
      # fingerprints, caught by the mimicry spec): Devise answers a POST with
      # 303, and a real signup with a grace period lands on its fresh
      # organisation -- so this one lands on an organisation that could be
      # fresh. Without a grace period Devise's inactive path goes to root.
      # root_path via the localized helper, see the note in BotTrapProtected: main_app
      # would answer "/" while the real inactive path answers "/de".
      target = grace_period ? main_app.organisation_root_path(SecureRandom.uuid) : root_path
      redirect_to target, status: :see_other
    end

    # without_tenant because this runs BEFORE the action, outside the block
    # that establishes it; the invitation is what the :new template expects.
    def bot_trap_reject(_reason)
      ActsAsTenant.without_tenant do
        @invitation = invitation_from_token
        reject_signup('flash.bot_trap.rejected')
      end
    end

    # The one shape every pre-create rejection shares: rebuild the resource
    # from the submitted params so the entered name and address survive, and
    # re-render the sign-up template explicitly with the sessionless layout
    # (determine_layout only picks it for action_name 'new').
    #
    # Returns true explicitly so the `reject_signup(...) and return` guards halt
    # on the RETURN VALUE, not on render happening to hand back a truthy body:
    # appending any statement here that evaluated to nil (a guarded logger call)
    # would otherwise silently disarm all three guards and fall through to super.
    def reject_signup(alert_key)
      self.resource = resource_class.new(sign_up_params)
      clean_up_passwords(resource)
      flash.now[:alert] = t(alert_key)
      render :new, layout: 'application_auth', status: :unprocessable_entity
      true
    end

    # Registration-closed gate, pulled ahead of the bot trap (see the
    # before_action declaration). Sets @invitation so #create reuses it.
    def ensure_registration_allowed
      ActsAsTenant.without_tenant do
        @invitation = invitation_from_token
        return if SystemSetting.allow_registration? || @invitation

        flash[:alert] = SystemSetting.registration_disabled_message
        redirect_to new_user_registration_path
      end
    end

    # The submitted user hash, guarded to an ActionController::Parameters. The
    # sign-up form's `user` key is attacker-controlled SHAPE: `user=x` arrives as
    # a String and `user[]=x` as an Array, and params.dig(resource_name, …) then
    # raises (String has no #dig; Array#dig wants an Integer) BEFORE any guard
    # runs -- an unauthenticated 500 on the public form. Every non-Devise read
    # of the user hash goes through here so that shape can never reach #dig,
    # controller AND view: reject_signup re-renders :new, which prefills its
    # fields from the same submitted params and would 500 in the template
    # otherwise (that is where the array-shape crash actually surfaced).
    # (sign_up_params is Devise's own, already guarded, and stays as it is.)
    helper_method :user_form_params
    def user_form_params
      raw = params[resource_name]
      raw.is_a?(ActionController::Parameters) ? raw : ActionController::Parameters.new
    end

    # A single SUB-key of the user hash, guaranteed scalar. user_form_params only
    # tames the top level; the values under it are still attacker-shaped:
    # user[terms_accepted][]=x arrives as an Array, and
    # ActiveModel::Type::Boolean.cast(["x"]) is true -- so an array value would
    # satisfy the consent gate, and an array/hash organisation_name would be
    # stored as its inspect string. A real form field is always scalar; a Hash,
    # Parameters or Array value collapses to nil. A key that is MEANT to be
    # nested reads user_form_params directly and is not routed here.
    helper_method :user_form_scalar
    def user_form_scalar(key)
      value = user_form_params[key]
      value.is_a?(ActionController::Parameters) || value.is_a?(Hash) || value.is_a?(Array) ? nil : value
    end

    # The invitation referenced by the token param, whatever its state — this is
    # what opens a CLOSED registration, deliberately including expired and
    # already-accepted ones (unchanged behaviour).
    #
    # The blank guard is load-bearing: invitations.token is nullable, so a bare
    # find_by(token: nil) can match an invitation whose token was never
    # generated. Such a record would have opened a closed registration for
    # anyone and prefilled a stranger's address into the form. The create path
    # always had this guard; new did not.
    def signup_hosted_elsewhere?
      Rails.application.config.x.signup_location.elsewhere?
    end

    def hosted_signup_url
      Rails.application.config.x.signup_location.url
    end

    def invitation_from_token
      # Memoised per request: ensure_registration_allowed, #create, bot_trap_reject
      # and valid_invitation each ask for it, so without this a single registration
      # POST ran the same Invitation lookup three times. The memo lives in
      # @invitation (NOT @invitation_from_token) on purpose: it is the raw token
      # record the :new template prefills from and the callers already assign it by
      # that name. valid_invitation keeps its own memo for the redeemable decision
      # across the accept flow.
      # rubocop:disable Naming/MemoizedInstanceVariableName
      return @invitation if defined?(@invitation)

      # to_s guards the SHAPE, not just presence: token[a]=1 arrives as a hash,
      # passes blank?, and find_by(token: {...}) raises TypeError (can't cast
      # Parameters) -- a 500 on GET /users/sign_up, which the registrations/ip
      # throttle (post-only) does not cover. A hash/array token stringifies to
      # something that simply matches no invitation.
      #
      # delete("\0") guards the CONTENT: "\0".blank? is false, but the pg adapter
      # refuses to bind a string with a null byte ("string contains null byte",
      # an ArgumentError), so ?token=%00 would 500 the public form -- and on a
      # CLOSED instance it 500s inside ensure_registration_allowed, BEFORE the bot
      # trap runs. Stripping NUL leaves a value that simply matches no invitation.
      token = params[:token].to_s.delete("\0")
      @invitation = token.blank? ? nil : Invitation.find_by(token: token)
      # rubocop:enable Naming/MemoizedInstanceVariableName
    end

    # The invitation this signup may actually REDEEM: present, still in its
    # 3-day TTL (out_of_date?, an `expired?` never existed on the model) and not
    # yet accepted. Memoised because the flow asks three times — build_resource
    # for the confirmation skip, then the organisation attachment, then the
    # acceptance stamp — and the last call happens after accepted_at was
    # written, where a fresh lookup would answer nil.
    def valid_invitation
      return @valid_invitation if defined?(@valid_invitation)

      invitation = invitation_from_token
      @valid_invitation =
        (invitation if invitation && !invitation.out_of_date? && invitation.accepted_at.nil?)
    end

    # Reads the raw consent checkbox from the sign-up form. `terms_accepted` is not
    # a User attribute, so it is checked directly on the params rather than through
    # the resource / strong parameters.
    def terms_accepted?
      ActiveModel::Type::Boolean.new.cast(user_form_scalar(:terms_accepted))
    end

    def determine_layout
      # Werkstatt split screen (design handoff 3b) for the sign-up form; the
      # create branch covers Devise's own re-render on validation errors.
      # registration_disabled keeps application_sessionless via its explicit
      # render in #new.
      if devise_controller? && resource_name == :user && %w[new create].include?(action_name)
        'application_auth'
      else
        'application'
      end
    end

    protected

    # :confirmable mails the instructions from an after_create callback, so the
    # skip has to happen BEFORE the save — build_resource is the hook that runs
    # there (the block passed to `super` in #create runs after it).
    #
    # An invited person receives no confirmation mail: the token was mailed to
    # exactly this address and is being redeemed right now, so the address is
    # already proven. A second link would be friction without a security gain.
    # Twin of the same call in Actors::AcceptInvitation#create_user, which
    # covers the other invitation flow (an existing account joining an org).
    #
    # The token proves ONE mailbox, so the account gets the invited address
    # whatever the form sent. Set here and not in the block #create passes to
    # `super`: Devise yields that block only AFTER the save. The skip compares
    # again anyway, so a later change to the assignment cannot silently confirm
    # an address nobody proved.
    #
    # The account also starts in the language its form was shown in
    # (ApplicationController#request_locale: a public page address or ?locale=,
    # then the last one this session chose, then the browser's Accept-Language,
    # then German). The column defaults to German, so an English visitor would
    # otherwise read English up to the button and German from the first page
    # after it. That includes invitees whose browser asks for English (decided
    # 14.09.2026 in the review of #816); the profile setting changes it later.
    def build_resource(hash = {})
      super
      if valid_invitation
        resource.email = valid_invitation.email
        resource.skip_confirmation! if valid_invitation.addressed_to?(resource.email)
      end
      resource.language_preference = I18n.locale.to_s
    end

    def configure_permitted_parameters
      devise_parameter_sanitizer.permit(:sign_up, keys: %i[first_name last_name])
      # No avatar keys here: the profile picture moved to the display section
      # of user_preferences, which does not sit behind the current-password
      # gate of update_with_password (user decision 04.09.2026).
      devise_parameter_sanitizer.permit(:account_update, keys: %i[first_name last_name])
    end
  end
end
