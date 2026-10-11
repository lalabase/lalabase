# frozen_string_literal: true

module Admin
  class AiCredentialsController < ApplicationController
    before_action :set_ai_credential,
                  only: %i[show edit update destroy activate toggle_enabled test_connection vertex_availability]

    def index
      @ai_credentials = Admin::AiCredential.ordered_by_provider
      @providers = Admin::AiCredential.providers
      @provider_stats = build_provider_stats
      credential_ids = @ai_credentials.ids
      @usage_by_credential = usage_30d_by_credential(credential_ids)
      # Which packages use which credential — resolved for the whole page up
      # front (two queries), never per row. Since three EU presets can share the
      # provider openai_compatible, the packages column is what tells them apart.
      #
      # Named apart from #show's flat list on purpose: one name carrying a Hash
      # here and an Array there is a trap for any partial either view later
      # shares (.fetch(id, []) vs .any?).
      @package_references_by_credential = AiPackage.references_by_credential(credential_ids)
    end

    def show
      @usage_stats = @ai_credential.usage_stats(30)
      @recent_usages = @ai_credential.ai_usages.recent(7).limit(10)
      # Flat list here (the index hands the view a hash keyed by credential):
      # drives both the "referenced by" section and the disabled delete button.
      @package_references = AiPackage.references_by_credential([@ai_credential.id]).fetch(@ai_credential.id, [])
      # Contract data (doc/ki_vertragsdaten_plan.md T3/T4). Documents with their
      # attachment preloaded: the list links every PDF, and without the preload
      # that is one blob query per row.
      @credential_documents = @ai_credential.documents.with_attached_file.newest_first.to_a
      @credential_contracts = @ai_credential.contracts.includes(:documents).order(starts_on: :desc).to_a
      # From the loaded array, NOT via #contract_on: `.includes(…)` spawns a new
      # relation, so the association stays unloaded. contract_on would take the
      # DB branch and return a second object WITHOUT preloaded documents, which
      # the view would then have to load again.
      @current_contract = @credential_contracts.find { |contract| contract.effective_on?(Date.current) }
      # Cache read only — a GET must never trigger the probe's network fan-out.
      return unless @ai_credential.provider == ::AiCredential::PROVIDER_GOOGLE

      @vertex_availability = Lalabase::Llm::VertexAvailabilityProbe.cached(credential_id: @ai_credential.id)
    end

    def new
      @ai_credential = Admin::AiCredential.new
    end

    def create
      @ai_credential = Admin::AiCredential.new(ai_credential_params)

      if @ai_credential.save
        Rails.logger.info "AI Credential created: #{@ai_credential.name} (#{@ai_credential.provider})"
        redirect_to admin_ai_credentials_path, notice: t('flash.admin.ai_credentials.created')
      else
        Rails.logger.error "AI Credential creation failed: #{@ai_credential.errors.full_messages.join(', ')}"
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      # Show masked token by default, only show full token if explicitly requested
      @show_full_token = params[:show_token] == 'true'
    end

    def update
      # Don't update access_token if it's masked (unchanged)
      update_params = ai_credential_params
      update_params.delete(:access_token) if update_params[:access_token]&.include?('*')

      if @ai_credential.update(update_params)
        Rails.logger.info "AI Credential updated: #{@ai_credential.name} (#{@ai_credential.provider})"
        redirect_to admin_ai_credentials_path, notice: t('flash.admin.ai_credentials.updated')
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      provider = @ai_credential.provider
      name = @ai_credential.name

      @ai_credential.destroy!
      Rails.logger.info "AI Credential deleted: #{name} (#{provider})"
      # see_other: the delete control is a link_to + data-turbo-method, so Turbo
      # issues a real DELETE fetch. Per the Fetch spec a 302 only downgrades
      # POST to GET — a DELETE is RE-ISSUED as DELETE against the redirect
      # target, and DELETE /admin/ai_credentials has no route. 303 is what makes
      # the follow-up a GET.
      redirect_to admin_ai_credentials_path, notice: t('flash.admin.ai_credentials.deleted'), status: :see_other
    rescue ActiveRecord::RecordNotDestroyed
      # A before_destroy threw :abort (AiCredentialDestroyProtection). The
      # exception itself only says "Failed to destroy the record" — the reason
      # sits in the record's errors, so show those instead.
      redirect_to admin_ai_credentials_path,
                  status: :see_other,
                  alert: t('flash.shared.delete_error', error: @ai_credential.errors.full_messages.to_sentence)
    rescue ActiveRecord::InvalidForeignKey
      # The NO ACTION FK from ai_packages fired between the guard's SELECT and
      # this DELETE (a package created in the meantime). Raw PG text names
      # constraints, tables and the failing SQL, so it stays out of the flash.
      redirect_to admin_ai_credentials_path,
                  status: :see_other,
                  alert: t('flash.admin.ai_credentials.delete_blocked')
    end

    def activate
      Admin::AiCredential.activate!(@ai_credential.id)
      redirect_back(
        fallback_location: admin_ai_credentials_path,
        notice: t('flash.admin.ai_credentials.activated', name: @ai_credential.name, provider: @ai_credential.provider_display_name)
      )
    rescue StandardError => e
      redirect_back(
        fallback_location: admin_ai_credentials_path,
        alert: t('flash.admin.ai_credentials.activate_error', error: e.message)
      )
    end

    def toggle_enabled
      @ai_credential.update!(enabled: !@ai_credential.enabled)
      notice_key = @ai_credential.enabled? ? 'flash.admin.ai_credentials.enabled' : 'flash.admin.ai_credentials.disabled'

      redirect_back(
        fallback_location: admin_ai_credentials_path,
        notice: t(notice_key, name: @ai_credential.name)
      )
    rescue ActiveRecord::RecordNotSaved
      # AiCredentialDestroyProtection threw :abort — disabling a credential an
      # AI package advertises has the same runtime effect as deleting it.
      redirect_back(
        fallback_location: admin_ai_credentials_path,
        alert: @ai_credential.errors.full_messages.to_sentence
      )
    end

    def test_connection
      if @ai_credential.test_connection
        redirect_back(
          fallback_location: admin_ai_credentials_path,
          notice: t('flash.admin.ai_credentials.connection_success', provider: @ai_credential.provider_display_name)
        )
      else
        redirect_back(
          fallback_location: admin_ai_credentials_path,
          alert: t('flash.admin.ai_credentials.connection_failed', provider: @ai_credential.provider_display_name)
        )
      end
    end

    # Live model-availability matrix (region × model) for google credentials —
    # the button always probes fresh (force_refresh), the cache only carries
    # the result across page loads (read in #show).
    def vertex_availability
      unless @ai_credential.provider == ::AiCredential::PROVIDER_GOOGLE
        return redirect_back(fallback_location: admin_ai_credential_path(@ai_credential),
                             alert: t('flash.admin.ai_credentials.vertex_availability_unsupported'))
      end

      Lalabase::Llm::VertexAvailabilityProbe.call(credential_id: @ai_credential.id, force_refresh: true)
      redirect_back(fallback_location: admin_ai_credential_path(@ai_credential),
                    notice: t('flash.admin.ai_credentials.vertex_availability_checked'))
    rescue Lalabase::Llm::VertexAvailabilityProbe::ProbeError, Lalabase::Llm::Provider::Error => e
      redirect_back(fallback_location: admin_ai_credential_path(@ai_credential),
                    alert: t('flash.admin.ai_credentials.vertex_availability_error', error: e.message))
    end

    private

    def set_ai_credential
      @ai_credential = Admin::AiCredential.find(params[:id])
    end

    def ai_credential_params
      params.require(:ai_credential).permit(
        :name, :provider, :access_token, :organization_id,
        :default_model, :active, :enabled, :description,
        # S2: effective name + endpoint (api_base supersedes additional_config.uri_base)
        # + purpose/region/quota + per-1M-token prices for CostCalculator.
        # company_domicile is E12's second jurisdiction axis (plan §3.3) — without
        # it in this list the new seam select would post and be dropped silently.
        :display_name, :purpose, :region, :company_domicile, :included_in_quota, :api_base,
        :input_cost_per_1m_cents, :output_cost_per_1m_cents, :embedding_cost_per_1m_cents,
        additional_config: {}
      )
    end

    # Aggregate 30d tokens + cost per credential in two grouped queries (constant,
    # not one query per row) so the list can show real consumption without an N+1.
    def usage_30d_by_credential(credential_ids)
      return {} if credential_ids.empty?

      scope = Admin::AiUsage.where(ai_credential_id: credential_ids).recent(30)
      tokens = scope.group(:ai_credential_id).sum(:tokens_used)
      costs = scope.group(:ai_credential_id).sum(:cost_cents)

      credential_ids.index_with do |id|
        { tokens: tokens[id].to_i, cost_cents: costs[id] || 0 }
      end
    end

    def build_provider_stats
      stats = {}

      Admin::AiCredential.providers.each do |provider|
        credentials = Admin::AiCredential.by_provider(provider)
        active_credential = credentials.active.first

        stats[provider] = {
          total: credentials.count,
          enabled: credentials.enabled.count,
          active: active_credential,
          usage_30d: Admin::AiUsage.by_provider(provider).recent(30).sum(:tokens_used),
          cost_30d: Admin::AiUsage.by_provider(provider).recent(30).sum(:cost_cents)
        }
      end

      stats
    end
  end
end
