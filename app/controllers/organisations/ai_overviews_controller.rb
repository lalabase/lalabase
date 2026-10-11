# frozen_string_literal: true

module Organisations
  # The AI area's hub (doc/ki_bereich_navigation_plan.md S2, decision N1;
  # doc/ki_uebersicht_zeilenliste_plan.md for the row list it renders since 09/2026).
  #
  # Not a dispatcher, an ANSWER. §3.2: the area is set up once and visited rarely, so
  # the overview has to settle "do I have to do anything?" in about three seconds and
  # most visits should end here without a click. The page says it in three places: one
  # sentence about the switch, one main action for the first open setup step, and a dot
  # on exactly the rows where something needs doing.
  #
  # ⚠️ Query budget: the whole page must not cost more than any detail page under it,
  # guarded by spec/requests/organisations/ai_overview_query_budget_spec.rb. §3.3 of the
  # plan opens with 5 and its Nachtrag of 2026-08-05 records why that number no longer
  # holds (the access row names package, rung AND jurisdiction, and the jurisdiction is
  # DERIVED from the credentials) — read the Nachtrag, not the headline. Two traps live
  # here:
  #   * NEVER call AiSyncStatusService from this action (Embeddings::IndexHealth exists
  #     for it, one query, same columns).
  #   * NEVER compute the switch ESTIMATE here — those four aggregates belong to
  #     #confirm_package, which is a page of its own for exactly that reason (E7).
  #     Progress (SwitchProgress) is cheap and welcome; the estimate is not.
  class AiOverviewsController < BaseController
    before_action :set_organisation
    before_action :authorize_ai_overview

    def show
      @package = current_package
      @tier = @package&.tier_for(@organisation.ai_package_tier_key)
      # Cheap by construction (see Embeddings::SwitchProgress) and the one state the hub
      # exists for: a staged switch runs for minutes to hours, the admin has nothing to
      # do about it, but wants to see it on the way in rather than hunt for it.
      @switch_progress = ::Embeddings::SwitchProgress.call(organisation: @organisation)
      @quota = @organisation.ai_quota_ledger
      @index_health = ::Embeddings::IndexHealth.call(organisation: @organisation)
      @persona_count = PromptPersona.where(organisation: @organisation).count
      # Two facts about the access, kept apart on purpose (plan D6). "Chosen" is the
      # setup question: has anybody decided who processes this organisation's content?
      # It drives the amber dot and the main action. "Available" is the operating
      # question, and it is asked the way every surface asks it (doc/ai_feature_registry_plan.md
      # E3, guarded by feature_registry_guard_spec Guard C): through the registry, never
      # through Organisation's low-level predicates. Every registered feature, because the
      # sentence says "keine KI-Funktion", not "kein Chat"; the operator's credential
      # counts, so an organisation that has chosen nothing can still be served. The
      # sentence at the top says "nothing works" only on the second, never on the first.
      @access_chosen = @package.present? || @organisation.ai_custom_access_configured?
      # The registry's resolution walks Factory.curated_package, i.e. organisation.ai_package,
      # and would load the package, its rungs and the rung's credential a second time
      # (measured: three queries). Handing the row already loaded above to the
      # association lets it judge the SAME object, rungs and credentials preloaded.
      @organisation.association(:ai_package).target = @package if @package
      @ai_available = @organisation.ai_enabled? &&
                      ::Lalabase::Llm::FeatureRegistry.keys.any? { |key| @organisation.ai_available_for?(key).available? }
      @protocol_since = protocol_since
    end

    private

    # The org's package WITH its credentials preloaded. The preload is not an
    # optimisation, it is the fix for a measured N+1: AiPackage#effective_jurisdiction
    # derives from referenced_credentials, i.e. one query per credential on a lazily
    # loaded row, and the row states the jurisdiction. P4e hit the same edge in
    # Actors::SelectAiPackage (Prosopite dropped 18 examples of it) and solved it the
    # same way — same scope, so the two cannot drift.
    #
    # nil is a legitimate answer: a blank ai_package_id means "Eigene Konfiguration"
    # (E1-C), which the row renders as its own state rather than as an absence.
    def current_package
      return nil if @organisation.ai_package_id.blank?

      AiPackage.with_customer_claims.find_by(id: @organisation.ai_package_id)
    end

    # Since when the protocol has entries: the oldest row of the trail the Protokoll
    # page lists (same scope, AiProtocolsController#protocol_scope), one aggregate on
    # index_activities_on_org_action_and_time. The card this row replaced refused any
    # figure from the database, and it was right about the source it had in mind: the
    # organisation's own columns hold only the LAST activation and package choice, so a
    # date built from them under-reports. The trail itself does not — its first entry
    # is its first entry. nil for an organisation that never changed anything.
    #
    # Tenant-scoped through acts_as_tenant, like the protocol page: #set_organisation
    # has put this org into ActsAsTenant.current_tenant before this runs.
    def protocol_since
      Activity.where(trackable_type: 'Organisation', action: AiProtocolActions::ALL)
              .minimum(:created_at)
    end

    # Membership-scoped lookup + tenant reset, verbatim the reasoning of
    # AiSettingsController#set_organisation: `current_user.organisations.find` raises
    # RecordNotFound for a non-member (404, no existence leak) instead of loading a
    # foreign org, and the tenant has to be reset because the policy checks
    # account_admin? against ActsAsTenant.current_tenant — leaving the session's org in
    # place would let the check pass against the wrong organisation.
    def set_organisation
      @organisation = current_user.organisations.find(params[:organisation_id])
      @current_organisation = @organisation
      ActsAsTenant.current_tenant = @organisation
    end

    def authorize_ai_overview
      authorize @organisation, :show?, policy_class: AiOverviewPolicy
    end
  end
end
