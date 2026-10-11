# frozen_string_literal: true

# In-app help: read-only browsing of the handbook, read from the catalogue file
# that gboyke/lalabase-documentation writes (doc/docs_delivery_plan.md, D4).
# Login-gated (ApplicationController default) but deliberately OUTSIDE the org scope — the help must also work from
# org-free pages (cockpit, user preferences) and for users without any org (D2
# revised, user decision 2026-07-03). The content is global and org-independent;
# an org context is picked up OPTIONALLY from the session so in-org users keep
# their full org sidebar (F1), while org-less users get the account shell.
class HelpController < ApplicationController
  include ViewportSwitchable

  # load_tenant_from_session bounces users WITHOUT a session org to the org
  # picker — that would make the help unreachable from exactly the org-free
  # pages this controller exists for. Resolve the org leniently instead.
  skip_before_action :load_tenant_from_session
  before_action :set_optional_organisation
  before_action :set_viewport_mode
  # Search state is loaded for every browsing action, not just :search — so a page
  # opened FROM a result (?q=…) re-renders the field + result list already filled,
  # and the suggestions survive the click instead of vanishing.
  before_action :load_search_state, only: %i[index show search]

  # /hilfe — desktop: straight to the first page (canonical slug URL);
  # mobile: the tree view — a redirect would trap mobile users away from the
  # navigation (DT7 pattern, see the inbox redirect lesson).
  def index
    return render_help_unavailable unless catalogue

    first = catalogue.first_page
    return render_help_not_found unless first

    if @viewport_mode == 'mobile'
      @groups = catalogue.groups(current_slug: first.slug)
      @active_slug = nil
    else
      redirect_to help_page_path(slug: first.slug)
    end
  end

  # /hilfe/*slug
  def show
    return render_help_unavailable unless catalogue

    @page = Docs::Catalogue.find_page(docs_locale, params[:slug])
    return render_help_not_found unless @page

    @groups = catalogue.groups(current_slug: @page.slug)
    @active_slug = @page.slug
    # @query (loaded by load_search_state, carried from the result link ?q=…) is
    # highlighted in the body; blank on a direct visit → no highlight.
    # Fallback banner (D9): the loader served the DE page for an EN request —
    # announce the language switch instead of silently swapping content.
    @language_fallback = @page.locale != docs_locale
    @body_html = Docs::HelpLinkRewriter.rewrite(@page.html, base_path: help_path,
                                                            catalogue: catalogue, locale: docs_locale)
    # The contextual-help drawer consumes ONLY the contextual_help_content frame —
    # skip the app shell (org sidebar incl. tenant queries, tree, search) for
    # frame requests, same pattern as #search below.
    render layout: false if turbo_frame_request?
  end

  # /hilfe/suche — Turbo-frame result list on the surface-scoped search (D10).
  def search
    # Turbo only extracts the frame — skip the app shell on every debounced
    # keystroke; direct visits keep the layout for debuggability.
    render layout: false if turbo_frame_request?
  end

  private

  # Query + result list for the sidebar search, shared by :search (the live frame)
  # and the browsing actions (so an opened result keeps the field + list filled).
  # Below the minimum term length the list stays empty (no "no results" noise while
  # typing the first character).
  def load_search_state
    @query = params[:q].to_s.strip
    @searched = @query.length >= Docs::Contract::MIN_TERM_LENGTH
    @results = @searched ? catalogue&.search(@query).to_a : []
  end

  # Lenient variant of load_tenant_from_session: restore the org shell when the
  # session points to an ACTIVE membership, otherwise render org-free — never
  # redirect. (An inactive membership must not resurrect the org sidebar here;
  # org routes send those users to the picker.)
  def set_optional_organisation
    membership = current_user.active_memberships.find_by(organisation_id: session[:current_organisation_id])
    return unless membership

    @current_membership = membership
    @current_organisation = membership.organisation
    # The org sidebar (project list, badges) queries tenant-scoped models.
    ActsAsTenant.current_tenant = @current_organisation
  end

  def docs_locale = Docs::Contract.locale_or_default(I18n.locale)

  # The reader's language, or German when this instance carries only that file.
  # The same fallback Docs::Catalogue.find_page makes for a single page, applied
  # to the navigation and the search around it, so the two cannot disagree.
  def catalogue
    return @catalogue if defined?(@catalogue)

    @catalogue = Docs::Catalogue.for(docs_locale) ||
                 Docs::Catalogue.for(Docs::Contract::DEFAULT_LOCALE)
  end

  # No catalogue at all: a self-hosted instance, or a machine that has not
  # fetched one. NOT an error and not an empty tree, both of which read as
  # broken. The documentation exists, it is just published elsewhere, so this
  # says where and links straight into it.
  def render_help_unavailable
    @public_docs_url = Docs::PublicDocs.url(locale: docs_locale)
    render :unavailable, layout: !turbo_frame_request?
  end

  def render_help_not_found
    # layout: true = default layout. Frame requests (the drawer fetching a stale
    # slug) skip the shell here too — the 404 view carries the frame itself.
    render :not_found, status: :not_found, layout: !turbo_frame_request?
  end
end
