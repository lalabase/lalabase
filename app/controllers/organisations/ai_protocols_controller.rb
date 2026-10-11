# frozen_string_literal: true

module Organisations
  # The AI area's protocol page (doc/ki_bereich_navigation_plan.md S5, L13/E5).
  #
  # The READ side of a trail that has been written since P4e (package and rung) and S0
  # (the on/off switch) and had no door at all: the only way in was a Rails console
  # query, and the public documentation said so in as many words (02-ai-byok.md, "Für
  # die Historie gibt es bislang keine Oberfläche"). §3.2 of the plan calls the entry
  # "Anzeige für etwas, das nur per Rails-Console erreichbar ist" — this is that display,
  # and it invents nothing: the wording of every row already exists as the i18n texts
  # Activity#message and #action_text render.
  #
  # Read-only on purpose. An audit trail with an edit path is not one, and the rows have
  # no owner in the UI sense: they belong to the AVV, not to the admin looking at them.
  class AiProtocolsController < BaseController
    # Page size, and the ceiling a request may raise it to. Both matter, and for
    # different reasons. PAGE_SIZE keeps the page from growing with the ORGANISATION'S
    # AGE — the trail has no upper bound and nothing ever deletes from it, so an
    # unpaginated version would be cheap on the day it ships and the most expensive page
    # in the area two years later, with no visible moment in between where it broke.
    # MAX_PAGE_SIZE is the ceiling for `?items=`. ⚠️ An earlier version of this comment
    # justified it with Organisations::BaseController#ensure_items_parameter injecting the
    # user's stored preference — that mechanism cannot fire here: it returns early unless
    # a Turbo-Frame header is present, and PaginationHelper::FRAME_IDS has no entry for
    # ai_protocols, so this page navigates with Turbo.visit rather than a frame load. On
    # THIS page `?items=` only ever comes from the URL.
    #
    # The ceiling stays anyway, for the plainer reason: the trail grows without bound and
    # nothing else stops a hand-typed number from loading all of it. (The stored
    # preference is a real mechanism on the frame-loaded lists — and ApplicationController
    # writes it back UNCAPPED from any request, which is a defect of its own, reported
    # separately and not this page's to fix.)
    #
    # 20 rather than a round-looking 25 so the page size is one of the options the
    # compact pagination nav offers (PaginationHelper::ITEMS_OPTIONS_COMPACT); a default
    # the selector cannot show renders as "nothing selected" and reads like a bug.
    PAGE_SIZE = 20
    MAX_PAGE_SIZE = 50

    before_action :set_organisation
    before_action :authorize_ai_protocol

    def show
      @pagy, @entries = pagy(protocol_scope, limit: page_limit)
    end

    private

    # ⚠️ The page size is resolved HERE rather than left to Pagy, and the reason is a
    # measured trap in both directions. `Pagy::Backend#pagy` runs
    # `vars[:limit] ||= pagy_get_limit(vars)`, so passing `limit:` short-circuits every
    # parameter mechanism Pagy has: the limit extra never runs, `limit_max:` is never
    # consulted (it is silently kept as just another var), and the selector in the
    # pagination footer would set `?items=` on a page that ignores it.
    #
    # The SECOND half of that reasoning has EXPIRED and is recorded here so nobody acts
    # on it: it used to argue that dropping `limit:` swaps one problem for another,
    # because config/initializers/pagy.rb was skipped in the test environment and the
    # cap would then differ between production and the environment testing it. That
    # initializer runs everywhere now.
    #
    # The arithmetic stays on the first half alone: the same numbers in every
    # environment, the selector does what it promises, and the ceiling is a plain
    # assertion in the spec rather than a claim about which extras happen to be loaded.
    # Worth revisiting together with the `items` vs `limit` knot documented at the
    # bottom of that initializer, not before.
    def page_limit
      requested = params[:items].presence.to_i
      return PAGE_SIZE unless requested.positive?

      requested.clamp(1, MAX_PAGE_SIZE)
    end

    # Newest first: this page is read to answer "what happened recently", and the entry
    # a reader wants first is the last one written. Older entries never change position
    # under a newer one, so paging back stays stable.
    #
    # ⚠️ Tenant-scoped through acts_as_tenant, NOT through an explicit organisation_id
    # here: #set_organisation puts this org into ActsAsTenant.current_tenant and
    # Activity's default scope does the rest (same mechanism the write side documents in
    # Actors::SelectAiPackage#log_choice). Without a tenant the query would raise, under
    # a foreign one it would list somebody else's audit trail — which is why the request
    # spec proves the separation with a SECOND organisation that has its own entries
    # rather than with an empty one.
    #
    # Two preloads, both against a measured N+1 rather than out of habit: every row
    # renders Activity#message, which reads `actor.full_name` and, through
    # #trackable_display_name, the trackable — one query per row each without them.
    # Filtering on `action` alone (not on trackable) is what the composite index
    # index_activities_on_org_action_and_time is for; the four verbs exist nowhere else
    # in the app, so there is nothing to narrow further.
    def protocol_scope
      # trackable_type explicitly, although every verb is written against the
      # organisation today: Activity#action_text resolves its label through
      # "#{trackable_type.underscore}.#{action}", so a fifth verb written against a
      # different trackable would pass the locale guard, appear on this page, and render
      # the humanised fallback instead of its sentence. Stating the assumption costs
      # nothing and turns a silent wrong row into no row.
      #
      # id as the tiebreaker: `recent` orders by created_at alone, so two entries sharing
      # a timestamp have no defined order between two requests — and offset pagination
      # can then show a row twice or not at all. Rare (one verb per request), but this is
      # a page whose whole purpose is being a complete record. `recent` itself is
      # untouched, it is used everywhere.
      Activity.where(trackable_type: 'Organisation', action: AiProtocolActions::ALL)
              .includes(:actor, :trackable)
              .recent
              .order(id: :desc)
    end

    # Membership-scoped lookup + tenant reset, verbatim the reasoning of
    # AiOverviewsController#set_organisation: `current_user.organisations.find` raises
    # RecordNotFound for a non-member (404, no existence leak) instead of loading a
    # foreign org, and the tenant has to be reset because the policy checks
    # account_admin? against ActsAsTenant.current_tenant.
    def set_organisation
      @organisation = current_user.organisations.find(params[:organisation_id])
      @current_organisation = @organisation
      ActsAsTenant.current_tenant = @organisation
    end

    def authorize_ai_protocol
      authorize @organisation, :show?, policy_class: AiProtocolPolicy
    end
  end
end
