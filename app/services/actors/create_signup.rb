# frozen_string_literal: true

# app/services/actors/create_signup.rb
#
# Tier-2 actor: one self-registration. The ONE place that decides whether a signup is
# allowed and creates it, shared by Users::RegistrationsController today and the
# provisioning endpoint the separate website will call (website split, step W2).
#
# All or nothing (owner decision D2, 15.09.2026): the user and their own organisation
# (role, membership, billing account via Actors::CreateOrganisation) commit in ONE
# transaction. Until then a failed organisation left a user without one, which neither the
# form nor an API caller could repair. The steps after that commit must never undo it and
# live in Signups::FollowUps: onboarding seed, acquisition source, founder request, audit.
#
# Tier 2 because the flow does not fit the #perform template: the language and the
# tenant-free scope wrap the whole run (the confirmation mail renders in the language on
# commit), and the follow-ups run after the commit, outside the transaction.
#
# Invitations are a different flow (join an existing organisation, no confirmation, no
# seed) and stay in the registrations controller.
module Actors
  class CreateSignup < BaseActor
    ORGANISATION_NAME_SUFFIXES = (2..99)

    # The organisation created with the user: the provisioning endpoint names it in its
    # response, and reading it back through the tenant scope would need a lifted tenant.
    attr_reader :founder_signup, :organisation

    # founder_signup: nil when not requested, else the FounderSignup::DECLARED_ATTRIBUTES
    #   plus :marketing_consent (only true counts).
    # acquisition: the stored AcquisitionSource hash, cleaned by the follow-ups.
    # request: whatever UserActivity.track! reads (remote_ip, user_agent, session.id), or nil.
    def initialize(email:, password:, first_name:, last_name:, language:, terms_accepted:,
                   password_confirmation: nil, organisation_name: nil, acquisition: nil,
                   founder_signup: nil, request: nil, current_user: nil)
      super()
      @email = email
      @password = password
      @password_confirmation = password_confirmation
      @first_name = first_name
      @last_name = last_name
      @language = language.to_s
      @terms_accepted = terms_accepted
      @organisation_name = organisation_name
      @acquisition = acquisition
      @founder_signup_attributes = founder_signup
      @request = request
      @current_user = current_user
    end

    def record
      @user
    end

    # The language wraps the error mapping, and not the other way round: the
    # messages of a RecordInvalid are rendered by with_error_mapping's rescue,
    # which runs AFTER the block returned. Nested the other way, a signup in
    # English came back with German validation errors. The form never showed it,
    # because there the ambient locale already IS the signup's language; through
    # the provisioning endpoint it was plain to see.
    def call
      return unsupported_language unless I18n.locale_available?(@language)

      I18n.with_locale(@language) do
        with_error_mapping do
          ActsAsTenant.without_tenant do
            verify_signup_allowed!
            ActiveRecord::Base.transaction { create_user_and_organisation! }
            @founder_signup = Signups::FollowUps.call(
              user: @user, organisation: @organisation, acquisition: @acquisition,
              founder_signup: founder_signup_draft, request: @request
            )
            success(@user)
          end
        end
      end
    end

    private

    # Routed through with_error_mapping like every other domain failure, so the
    # mapping policy stays in the one place the actor contract puts it. Cannot
    # run inside I18n.with_locale: the language is the thing that is wrong.
    def unsupported_language
      with_error_mapping do
        raise ActorError.new(["unsupported language #{@language.inspect}"], code: :invalid_language)
      end
    end

    # Same order as the form always checked, so a submission with several problems keeps
    # getting the same first message.
    def verify_signup_allowed!
      raise ActorError.new([SystemSetting.registration_disabled_message], code: :registration_closed) unless SystemSetting.allow_registration?
      raise ActorError.new([I18n.t('flash.registrations.accept_terms')], code: :terms_not_accepted) unless @terms_accepted == true
      raise ActorError.new([I18n.t('flash.registrations.disposable_email')], code: :disposable_email) if DisposableEmailDomains.match?(@email)
      raise ActorError.new([I18n.t('flash.registrations.founder_signup_incomplete')], code: :founder_signup_incomplete) unless founder_signup_draft_valid?
    end

    # The terms are accepted with the insert (Art. 13 GDPR proof), not in a second write.
    def create_user_and_organisation!
      @user = User.new(email: @email, password: @password, password_confirmation: @password_confirmation,
                       first_name: @first_name, last_name: @last_name,
                       language_preference: @language, terms_accepted_at: Time.current)
      @user.save!
      create_organisation!
    end

    # Organisation names are unique across the instance, and both a submitted name and the
    # email-derived default can be taken already: one retry with a numbered variant. Each
    # attempt runs in its own savepoint, so a failed one leaves nothing behind in the
    # signup's transaction.
    def create_organisation!
      desired_name = @organisation_name.to_s.strip.presence || default_organisation_name
      organisation, result = attempt_organisation(desired_name)
      organisation, result = attempt_organisation(next_free_organisation_name(desired_name)) if !result.success? && organisation.errors.of_kind?(:name, :taken)
      raise ActorError.new(result.errors.presence || [I18n.t('flash.registrations.organisation_creation_failed')], code: :organisation_creation_failed) unless result.success?

      @organisation = organisation
    end

    def attempt_organisation(name)
      organisation = Organisation.new(name: name)
      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        result = Actors::CreateOrganisation.call(organisation: organisation, owner: @user, current_user: @user)
        raise ActiveRecord::Rollback unless result.success?
      end
      [organisation, result]
    end

    def default_organisation_name
      "#{@email.to_s.split('@').first.to_s.capitalize}'s Organisation"
    end

    # Best effort only: the uniqueness validation stays the authority. If a racer takes the
    # variant between this check and the insert, the signup fails with the alert instead of
    # looping.
    def next_free_organisation_name(base)
      ORGANISATION_NAME_SUFFIXES.each do |suffix|
        candidate = "#{base} #{suffix}"
        return candidate unless Organisation.exists?(name: candidate)
      end
      "#{base} #{SecureRandom.hex(3)}"
    end

    # Built once: the same object is validated before the user exists and saved after the
    # account exists, so the check and the write cannot disagree.
    def founder_signup_draft
      return if @founder_signup_attributes.nil?

      @founder_signup_draft ||= begin
        attributes = @founder_signup_attributes.to_h.symbolize_keys
        consent = attributes[:marketing_consent] == true
        FounderSignup.new(attributes.slice(*FounderSignup::DECLARED_ATTRIBUTES)
                                    .merge(marketing_consent: consent, marketing_consent_at: (Time.current if consent)))
      end
    end

    # The draft has no account yet; that error is expected here and is the only one that
    # does not belong to the applicant.
    def founder_signup_draft_valid?
      return true if founder_signup_draft.nil?

      founder_signup_draft.valid?
      founder_signup_draft.errors.none? { |error| error.attribute != :account }
    end
  end
end
