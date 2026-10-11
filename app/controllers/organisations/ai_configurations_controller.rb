# frozen_string_literal: true

module Organisations
  # "Eigene Konfiguration" — the setup screen behind the catalogue's own-configuration
  # card (doc/ki_bereich_navigation_plan.md S7, decision E6 Weg A).
  #
  # What it replaces: a form that sat UNDER the package catalogue on the settings page
  # and asked the same question a second time, with two axes (a provider select and a
  # use_system_credentials radio) that an inline <script> toggled against each other.
  # Five of the plan's thirteen gaps lived in it and P2 skipped rather than replaced it
  # (§4 Bilanz). All five are the content of this controller and its screen:
  #
  #   L3  the write no longer drops a stored key as a side effect — Actors::
  #       SaveAiConfiguration keeps it, and #destroy is the explicit way to remove one.
  #   L5  "prüfen" runs AFTER the save, so it can no longer report success for a key
  #       that is not the one in the field (E3-A).
  #   L6  the probe is gate-free (Lalabase::Llm::ConnectionCheck), so "configure first,
  #       switch on afterwards" stops being the one order the button refuses.
  #   L7  the fields are per provider, and ai_api_base and preferred_chat_model get
  #       their first UI in this app at all.
  #   L10 the verdict is persisted and feeds the hub card.
  #
  # The SECOND axis is gone rather than moved: there is no "use system credentials"
  # choice here, because that choice IS the catalogue. Picking a package (or the
  # own-configuration card) is the selection; this screen only answers "with which
  # access", and that is what L4 asked for — navigation, not a form state.
  class AiConfigurationsController < BaseController
    include AiConnectionCheckable

    before_action :set_organisation
    before_action :authorize_ai_configuration

    # Flat keys, not a nested model hash: the write goes through an Actor whose contract
    # is a plain params hash, and Organisation is not a form object here (four of these
    # five columns must never be mass-assignable from anywhere else). The list is the
    # Actor's own, so a column added there cannot silently stay unreachable.
    PERMITTED = Actors::SaveAiConfiguration::WRITABLE

    def show
      load_form
    end

    def update
      result = Actors::SaveAiConfiguration.call(organisation: @organisation,
                                                params: configuration_params,
                                                current_user: current_user)
      return render_invalid(result) unless result.success?

      # E3-A, and the ORDER is the decision: save, then probe. The probe reads the stored
      # configuration, so probing first would once again test something other than what
      # the admin typed — which is L5, just moved one line up.
      return redirect_to(configuration_path, notice: t('flash.ai_configurations.saved')) unless check_requested?

      redirect_to configuration_path, **ai_connection_check_flash(@organisation)
    end

    # DELETE — "Zugang entfernen" (E2a). Its own action and its own verb because the
    # save deliberately cannot do it: a blank key field means "keep the stored one", so
    # removal has to be asked for. See Actors::RemoveAiConfiguration for why this is a
    # precondition of the save rather than a convenience.
    #
    # ⚠️ The result IS checked, and the reason is that the actor's own header says it
    # "does NOT refuse" — which is true of its DOMAIN rules and says nothing about the
    # write. A failed validation, a StaleObjectError from the lock!, or in production any
    # unexpected error all come back as a failure Result rather than an exception
    # (BaseActor#with_error_mapping re-raises only in dev/test). An unchecked call
    # therefore announced "Der eigene Zugang wurde entfernt" while the token was still
    # stored — measured. On an action whose confirmation dialog says the removal cannot be
    # undone, a success message for a write that did not happen is the worst of the two
    # possible lies: the admin stops looking.
    #
    # Redirect rather than the #update path's re-render: there is nothing typed to
    # preserve here, and re-rendering :show for a DELETE would leave the browser on a URL
    # that does not answer GET the same way.
    def destroy
      result = Actors::RemoveAiConfiguration.call(organisation: @organisation, current_user: current_user)
      return redirect_to(configuration_path, alert: result.errors.join(' ')) unless result.success?

      redirect_to configuration_path, notice: t('flash.ai_configurations.removed')
    end

    private

    # Two submit buttons, ONE action and one write — the answer to L9, which counted two
    # save buttons with unclear semantics. Both save; only this one additionally probes.
    # A separate route for "prüfen" would be a second write path to the same columns,
    # which is the shape the whole slice exists to remove.
    def check_requested?
      params[:check].present?
    end

    def configuration_params
      params.permit(*PERMITTED).to_h.symbolize_keys
    end

    # Re-renders with what the admin typed still in the fields. The Actor assigns the
    # attributes to THIS record before it refuses, and its transaction rolls back the
    # database rather than the object — so the form shows the rejected combination and
    # the message explaining it, instead of silently reverting to the stored state and
    # leaving the admin to guess what was wrong.
    #
    # The key is the one exception, and it is not an oversight: it is never echoed back
    # (Organisation#masked_ai_token is the only rendering of it anywhere).
    def render_invalid(result)
      flash.now[:alert] = result.errors.join(' ')
      load_form
      render :show, status: :unprocessable_entity
    end

    def load_form
      # S1 honest facade, same list as the settings page: only offer providers the
      # Factory can actually build.
      @provider_options = AiCredential.provider_options_for_select
      @selected_provider = @organisation.ai_provider.presence || AiCredential::PROVIDER_OPENAI
      @has_own_access = @organisation.has_own_ai_credentials?(@selected_provider)
      @masked_token = @organisation.masked_ai_token
    end

    def configuration_path
      organisation_ai_configuration_path(@organisation)
    end

    # Membership-scoped lookup + tenant reset, verbatim the reasoning of
    # AiSettingsController#set_organisation and its three siblings in this area:
    # `current_user.organisations.find` raises RecordNotFound for a non-member (404, no
    # existence leak) instead of loading a foreign org, and the tenant has to be reset
    # because the policy checks account_admin? against ActsAsTenant.current_tenant.
    #
    # ⚠️ It matters more here than on the read-only pages of the area: without the
    # reset, an account_admin of org A could reach org B's key fields.
    def set_organisation
      @organisation = current_user.organisations.find(params[:organisation_id])
      @current_organisation = @organisation
      ActsAsTenant.current_tenant = @organisation
    end

    # AiSettingsPolicy, not a policy named after this page — deliberately unlike the
    # other pages of the area, which each got their own. This screen writes the very
    # columns AiSettingsPolicy#update? has always governed, and the same argument
    # AiSettingsController#select_package makes applies: a second policy method for the
    # same right is a place for the two to drift apart.
    def authorize_ai_configuration
      authorize @organisation, :update?, policy_class: AiSettingsPolicy
    end
  end
end
