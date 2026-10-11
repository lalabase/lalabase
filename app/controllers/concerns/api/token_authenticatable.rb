# frozen_string_literal: true

# Auth layer for API controllers using a Personal Access Token.
#
# Two-step pattern:
#   1) authenticate_with_token!  → sets Current.user, no tenant (token can be multi-org)
#   2) with_organisation_scope(org) / with_project_scope(project)
#      → checks token scope, sets ActsAsTenant for the block
#
# On missing or invalid token: 401 (no existence leak needed).
# On scope violation: ActiveRecord::RecordNotFound → translated to 404 by the base controller.
module Api
  module TokenAuthenticatable
    extend ActiveSupport::Concern

    LAST_USED_THROTTLE = 1.minute

    included do
      before_action :authenticate_with_token!
      # Declared AFTER the authentication, so it wraps only an authenticated
      # request (a 401 halts the chain before it).
      around_action :with_token_owner_locale
    end

    private

    # Every user-facing text of a token request (validation messages an actor
    # answers, the presenter sentence of an inbox row) is rendered in the token
    # owner's profile language. I18n.locale is thread state, and a token request
    # never passes ApplicationController#switch_locale (ActionController::API), so
    # without this wrap an API or MCP request would answer in whatever language
    # the thread was left in. Notifications::Serializer keeps its own
    # with_locale(viewer) for callers outside a request (console, jobs); inside
    # one the two agree.
    def with_token_owner_locale(&block)
      I18n.with_locale(current_user.language_preference.presence || I18n.default_locale, &block)
    end

    def authenticate_with_token!
      raw = request.headers['Authorization']&.sub(/\ABearer /, '')
      pat = PersonalAccessToken.authenticate(raw)

      # pat.user is nil when the owner's row is soft-deleted (SoftDeletable
      # default scope): a credential must not outlive its account, so an erased
      # owner gets the same 401 as an unknown token (no existence leak). Defence
      # in depth on top of PersonalDataErasure#revoke_personal_access_tokens!.
      #
      # The same 401 when the owner could not sign in right now (locked,
      # unconfirmed past the grace period, system account): Devise's own
      # sign-in rule, so a token never reaches further than a password would.
      if pat.nil? || !pat.user&.active_for_authentication?
        render json: { error: 'unauthorized' }, status: :unauthorized
        return
      end

      @current_token = pat
      Current.user = pat.user
      touch_last_used_at(pat)
    end

    # Throttle: only once per minute per token, otherwise a write storm.
    # update_column DELIBERATELY: no callbacks/validation, only the one column.
    def touch_last_used_at(pat)
      return if pat.last_used_at && pat.last_used_at > LAST_USED_THROTTLE.ago

      pat.update_column(:last_used_at, Time.current)
    end

    def current_token
      @current_token
    end

    def current_user
      Current.user
    end

    # Sets ActsAsTenant for the given org and checks the token scope.
    # Unauthorized access → RecordNotFound (base controller returns 404).
    def with_organisation_scope(organisation, &block)
      raise ActiveRecord::RecordNotFound unless current_token&.accessible_organisation?(organisation)

      ActsAsTenant.with_tenant(organisation, &block)
    end

    # Like with_organisation_scope, but additionally checks the project scope.
    def with_project_scope(project, &block)
      raise ActiveRecord::RecordNotFound unless project
      raise ActiveRecord::RecordNotFound unless current_token&.accessible_project?(project)

      ActsAsTenant.with_tenant(project.organisation, &block)
    end
  end
end
