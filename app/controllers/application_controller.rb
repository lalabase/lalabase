# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # features_path and its siblings answer in the current language. Included here as well
  # as in the views because redirects and mailers build paths from the controller side.

  # The language first, ahead of authenticate_user!: Devise translates its sign-in hint in
  # the language current at that moment (see switch_locale).
  around_action :switch_locale
  before_action :authenticate_user!, unless: -> { devise_controller? && action_name == 'new' }
  before_action :load_tenant_from_session, if: :user_signed_in?
  before_action :update_items_per_page_from_params, if: :user_signed_in?
  before_action :load_user_preferences, if: :user_signed_in?
  before_action :set_current_attributes, if: :user_signed_in?
  before_action :touch_last_seen, if: :user_signed_in?

  # Paths that survive the org redirect below (N2 of doc/billing_stammdaten_plan.md):
  # the billing area, with or without a query string. Anchored so that an unrelated route
  # merely containing the word does not slip through.
  #
  # BOTH shapes, and the account one is the important half (K3 of
  # doc/konto_ebene_plan.md): /billing/:id is the canonical link now, so leaving it out
  # would mean exactly the reminder mails of the Stripe phase stop surviving the login,
  # while the org shortcut they no longer point at keeps working.
  # Two alternatives rather than one clever pattern with optional parts: the org
  # shortcut only ever has the two shapes it always had, and widening it by accident
  # while adding the account paths is exactly the mistake this spells out.
  #
  # The invitation page is the third alternative. An invitee who already has an account
  # must sign in before accepting (Organisations::AcceptInvitationsController, account
  # takeover fix of 26.09.2026), and that invitee is precisely someone with organisations
  # of their own: without this entry the org redirect would swallow the invitation and
  # leave them on their old home page.
  DEEP_LINK_AFTER_SIGN_IN = %r{
    \A(/org/[^/]+/billing(/edit)?|/billing(/[^/?]+)?(/edit)?|/org/[^/]+/accept_invitation)(\?|\z)
  }x

  def after_sign_in_path_for(resource)
    # Load user preferences into session after login
    load_user_preferences_for(resource)

    stored = stored_location_for(resource)

    # N2: the org redirect below normally WINS over a stored location, which quietly
    # swallowed every deep link for a user who has any organisation. That is fine for
    # ordinary pages -- the org root is where they want to be -- but not for the billing
    # hub, which is exactly the target of the mails the Stripe phase will send ("payment
    # reminder", "your billing details are incomplete"). Reading `stored` above also
    # CONSUMES it, so the session does not keep a stale location around either way.
    return stored if stored&.match?(DEEP_LINK_AFTER_SIGN_IN)

    return user_home_path(resource) if resource.organisations.any?

    stored || user_home_path(resource)
  end

  # Where a signed-in user belongs when no particular page was asked for. ONE
  # owner for that question: sign-in uses it, and so does the bare domain.
  #
  # Without an organisation this is the cockpit, NOT root_path -- that one is
  # remapped to /de, so a user in that state used to land on the marketing page.
  def user_home_path(user)
    organisation = user.organisations.first
    organisation ? organisation_root_path(organisation) : select_organisation_path
  end
  helper_method :user_home_path

  include Pundit::Authorization
  include Pagy::Backend
  # selectable_projects belongs HERE, not only on Organisations::BaseController:
  # the layout renders the global search form behind global_search_available?
  # (below), and HelpController restores the session organisation outside that
  # base. A deleted, unscoped helper used to cover the gap silently; without it
  # every full help page raised NameError (spec/requests/help_inside_organisation_spec.rb).
  include Organisations::ProjectScoping
  # Declares its own before_action, scoped to anonymous HTML GETs. Included
  # AFTER the callbacks above so it never runs ahead of the tenant/locale setup
  # for a signed-in request -- it skips those entirely anyway.
  include AcquisitionTracking
  # After switch_locale, so the refusal speaks the visitor's language.
  include DemoRestrictions

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  private

  def load_tenant_from_session
    return unless user_signed_in? # Check whether a user is signed in

    # If an organisation_id is provided in params, prefer it and set tenant
    if params[:organisation_id].present?
      begin
        organisation = current_user.organisations.find(params[:organisation_id])
        ActsAsTenant.current_tenant = organisation
        @current_organisation = organisation
        @current_membership = current_user.active_memberships.find_by(organisation: organisation)
        session[:current_organisation_id] = organisation.id
        return
      rescue ActiveRecord::RecordNotFound
        # Ignore and continue to other resolution strategies
      end
    end

    # If a tenant is already set (e.g., by tests or middleware), respect it and avoid redirects
    if defined?(ActsAsTenant) && ActsAsTenant.current_tenant.present?
      @current_organisation = ActsAsTenant.current_tenant
      @current_membership = current_user.active_memberships.find_by(organisation: @current_organisation)
      return
    end

    if session[:current_organisation_id].present?
      begin
        organisation = current_user.organisations.find(session[:current_organisation_id])
        ActsAsTenant.current_tenant = organisation
        @current_organisation = organisation
        @current_membership = current_user.active_memberships.find_by(organisation: organisation)
      rescue ActiveRecord::RecordNotFound
        # Organisation not found or user no longer has access
        session.delete(:current_organisation_id)
        redirect_to select_organisation_path if current_user.organisations.count > 0
      end
    elsif current_user.organisations.count > 0
      # Redirect only if we are not already on the way to the organisation selection
      redirect_to select_organisation_path unless controller_name == 'organisations' && action_name == 'select'
    end
  end

  def user_not_authorized
    flash[:alert] = t('shared.errors.not_authorized')
    # redirect_back, not raw request.referer: a cross-host Referer header
    # (user-controlled) raised UnsafeRedirectError (-> 500) on every Pundit
    # denial; redirect_back degrades to the fallback instead.
    redirect_back fallback_location: root_path
  end

  def current_organisation
    @current_organisation || @current_membership&.organisation
  end

  attr_reader :current_project

  helper_method :current_organisation, :current_project

  # Single source for the global-search access GATE: signed in, inside an organisation,
  # and allowed to read projects or time sessions. Shared by the search overlay (view)
  # and the search-pin toggle (SearchPinsController) so the two can never drift apart.
  # The `user_signed_in?` short-circuit is load-bearing: ProjectPolicy#index? calls
  # `user.active_organisations`, which would blow up on a nil user.
  # NOTE: the org-nav block in _navigation_application reuses the same policy combo to
  # gate the WHOLE org navigation (overview/inbox/times), not just search — that is
  # deliberately a separate condition, not this predicate.
  def global_search_available?
    user_signed_in? && current_organisation.present? &&
      (policy(Project).index? || policy(TimeSession).index?)
  end
  helper_method :global_search_available?

  # Single source for the ASSISTANT gate (S3a T4), same shape and same reason as
  # global_search_available? above: the sidebar row, the permanent panel shell in
  # the layout and AssistantPanelsController all have to agree — and unlike the
  # search overlay, the shell rides on EVERY page, so a condition that drifts
  # leaks the panel everywhere at once. The gate itself lives in ChatPolicy
  # (§13-2 pair: operator flag plus the use_assistant permission, both against an
  # ACTIVE membership); this is only its view-side door.
  def assistant_available?
    user_signed_in? && current_organisation.present? &&
      ChatPolicy.assistant_gate_open?(current_user, current_organisation)
  end
  helper_method :assistant_available?

  # The panel's open/width state as the browser last left it (§7.7). Read here so
  # the layout can render <main> ALREADY shifted, instead of the page jumping
  # once the Stimulus controller connects.
  def assistant_panel_state
    @assistant_panel_state ||= AssistantPanelState.from_cookie(cookies[AssistantPanelState::COOKIE_NAME])
  end
  helper_method :assistant_panel_state

  # Helper method to cache user's accessible projects for navigation
  helper_method :cached_user_projects, :sidebar_project_groups

  def cached_user_projects
    @cached_user_projects ||= if user_signed_in?
                                current_user.organisations
                                            .includes(:projects)
                                            .flat_map { |org| projects_with_organisation_preloaded(org) }
                                            .uniq
                                            .select { |p| policy(p).show? }
                                            .sort_by(&:name)
                              else
                                []
                              end
  end

  # We already loaded `org` (and its projects via includes), so hand each project
  # back its parent organisation. Otherwise the per-project `project.organisation`
  # read in the sidebar (chat-feature gate, settings permission) would re-query the
  # org once per project — an N+1 across the whole sidebar list. Returns the projects.
  def projects_with_organisation_preloaded(org)
    org.projects.each { |project| project.association(:organisation).target = org }
  end

  def sidebar_project_groups
    @sidebar_project_groups ||= SidebarProjectGroupingService.new(
      current_user, current_organisation,
      projects: cached_user_projects,
      current_project: current_project
    ).call
  end

  # Update items_per_page from URL params if present (persists to DB)
  def update_items_per_page_from_params
    return unless user_signed_in? && params[:items].present?

    new_value = params[:items].to_i
    return unless new_value > 0

    current_user.preference_store.set_items_per_page(new_value) if current_user.respond_to?(:preference_store)
  end

  # Load user preferences (no-op, preferences are read from DB on demand via Pageable)
  def load_user_preferences
    # Preferences are now read directly from DB via Pageable#items_per_page
  end

  # Load preferences for a specific user (no-op, read from DB on demand)
  def load_user_preferences_for(user)
    # Preferences are now read directly from DB via Pageable#items_per_page
  end

  # Helper method to get current items per page setting
  def current_items_per_page
    if respond_to?(:items_per_page)
      items_per_page
    elsif user_signed_in? && current_user.respond_to?(:items_per_page_preference)
      value = current_user.items_per_page_preference
      value.present? && value.to_i > 0 ? value.to_i : 20
    else
      20
    end
  end

  helper_method :current_items_per_page

  # The last language this session chose explicitly (the address of a public page or a
  # ?locale= parameter), for the pages after it that carry no language. The key keeps its
  # old name so sessions from before ?locale= existed stay valid.
  PUBLIC_LOCALE_SESSION_KEY = :public_locale

  # ONE answer per request to "which language?", and the thread handed back as it was.
  # I18n.locale is thread state and outlives the request. Until 10.09.2026 two
  # before_actions only ever SET it (the profile for a signed-in user, the address for a
  # public page), so a page with neither, seen by someone not signed in (sign-up, sign-in,
  # an invitation), inherited the language of the thread's previous request. with_locale
  # restores it afterwards, also for an action that changes it itself (the language
  # setting; until D5 the public documentation controller did the same).
  def switch_locale(&)
    I18n.with_locale(request_locale, &)
  end

  # On the public demo, its one language (Lalabase::Demo::LOCALE), before anything
  # else: the world is written in it, and nobody's choice can stick to the login
  # every visitor shares. Otherwise, in this order:
  # 1. A supported locale in the query string. Remember it for the Devise pages
  #    that follow without a locale parameter.
  # 2. The signed-in user's profile language.
  # 3. The last language this session chose explicitly (1. on an earlier page).
  # 4. The browser's best supported Accept-Language entry.
  # 5. German.
  #
  # There used to be a rung above all of these: a language in the PATH, which won
  # over every implicit preference. It went with D5
  # (doc/docs_delivery_plan.md). `/docs/:locale/...` were the last routes in this
  # application carrying a language in the path -- the public pages had taken
  # theirs with them at W6 -- so `request.path_parameters[:locale]` can no longer
  # be set by any route, on our server or on a self-hosted instance. Keeping the
  # branch would have meant keeping a rung that no address can reach and no spec
  # can exercise without drawing a route of its own.
  #
  # Whoever adds a locale-prefixed route brings it back: read
  # `request.path_parameters[:locale]` FIRST, and remember it like the query
  # locale below.
  #
  # ⚠️ request.query_parameters, NOT params. Reading params forces Rails to parse the
  # request body, and this runs on EVERY controller -- including the mail webhooks, whose
  # own error handling turns a malformed JSON body into a 400. Through params, the parse
  # error was raised here instead, one callback earlier, and the webhook answered 500.
  def request_locale
    return Lalabase::Demo::LOCALE if Lalabase::Demo.enabled?

    query_locale = supported_locale(request.query_parameters['locale'])
    if query_locale
      remember_chosen_locale(query_locale)
      return query_locale
    end

    profile_locale = supported_locale(current_user.language_preference) if user_signed_in?
    profile_locale || remembered_chosen_locale || browser_locale || I18n.default_locale
  end

  # A string, because the cookie session is JSON and would hand a symbol back as one.
  # Written only when it changes, so a visitor reading along in one language does not
  # rewrite the session on every page.
  def remember_chosen_locale(locale)
    return if session[PUBLIC_LOCALE_SESSION_KEY] == locale.to_s

    session[PUBLIC_LOCALE_SESSION_KEY] = locale.to_s
  end

  def remembered_chosen_locale
    supported_locale(session[PUBLIC_LOCALE_SESSION_KEY])
  end

  # The core's own locale list, not PublicRouteSegments: the public pages leave the core,
  # the language choice stays.
  def supported_locale(value)
    locale = value.to_s
    locale.to_sym if locale.present? && I18n.locale_available?(locale)
  end

  def browser_locale
    candidates = request.get_header('HTTP_ACCEPT_LANGUAGE').to_s.split(',').filter_map.with_index do |entry, index|
      language_range, *parameters = entry.strip.split(';').map(&:strip)
      quality_parameter = parameters.find { |parameter| parameter.downcase.start_with?('q=') }
      quality = quality_parameter ? Float(quality_parameter.split('=', 2).last, exception: false) : 1.0
      next unless quality&.between?(0.0, 1.0) && quality.positive?

      locale = supported_locale(language_range.to_s.downcase.split('-', 2).first)
      [locale, quality, index] if locale
    end

    candidates.max_by { |_locale, quality, index| [quality, -index] }&.first
  end

  # Set Current attributes for request-local storage
  def set_current_attributes
    Current.user = current_user
    Current.organisation = current_organisation
  end

  # Presence heartbeat: record that the signed-in user is active right now.
  # Guarded by #stale_last_seen? so it issues at most one UPDATE per
  # User::Presence::SEEN_THROTTLE; is_ai accounts (system/AI users) never get a
  # presence timestamp. The write is callback-free (see User::Presence).
  def touch_last_seen
    return if current_user.is_ai?
    return unless current_user.stale_last_seen?

    current_user.mark_seen!
  end
end
