# frozen_string_literal: true

module Admin
  # Operator CRUD for the curated AI offerings (KI-Pakete,
  # doc/ki_pakete_plan.md §7b.1). ai_packages is a GLOBAL table with no
  # organisation_id, so there is no tenant problem and no Admin:: twin model:
  # this works directly on the runtime AiPackage (pattern:
  # Admin::PromptPersonasController). Authorization comes from
  # Admin::ApplicationController's Admin::Authentication include (Beuser
  # session) — NOT Pundit.
  #
  # Credentials are the stock room, packages the shop window; both directions
  # are cross-linked (form + show link every referenced credential to its
  # detail page).
  class AiPackagesController < Admin::ApplicationController
    before_action :set_ai_package, only: %i[show edit update destroy vertex_check]
    before_action :load_credential_choices, only: %i[new create edit update]

    helper_method :ai_credential_option_label

    def index
      @ai_packages = AiPackage.ordered.includes(:tiers)
    end

    def show
      # Cache read only — a GET must never trigger the probe's network fan-out
      # (same rule as the credential detail page); #vertex_check probes fresh.
      @vertex_checks = vertex_checks_for(@ai_package)
    end

    def new
      @ai_package = AiPackage.new
      build_missing_tiers(@ai_package)
    end

    def create
      @ai_package = AiPackage.new(ai_package_params)
      # Forced, not taken from params: this form only ever creates curated
      # packages. A physical 'custom' row (card "Eigene Konfiguration") is a P2
      # decision and would come from db/seeds (§7b.1).
      @ai_package.kind = AiPackage::CURATED

      if save_package(@ai_package)
        redirect_to admin_ai_packages_path, notice: t('flash.admin.ai_packages.created')
      else
        build_missing_tiers(@ai_package)
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      build_missing_tiers(@ai_package)
    end

    def update
      if save_package(@ai_package) { @ai_package.assign_attributes(ai_package_params) }
        redirect_to admin_ai_packages_path, notice: t('flash.admin.ai_packages.updated')
      else
        build_missing_tiers(@ai_package)
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @ai_package.destroy!
      redirect_to admin_ai_packages_path, notice: t('flash.admin.ai_packages.deleted')
    rescue ActiveRecord::InvalidForeignKey
      # The DB refused because something still points at this package. The raw
      # PG text names constraints, tables and the failing SQL — deliberately NOT
      # forwarded into a flash that Admin::ApplicationController also keeps in
      # the session. Anything OTHER than this raises, so a real bug reaches
      # monitoring instead of looking like a business refusal.
      redirect_to admin_ai_packages_path, alert: t('flash.admin.ai_packages.delete_blocked')
    end

    # Fresh availability probe for every google credential this package
    # references. POST because it costs network I/O; #show only reads the cache
    # this fills.
    def vertex_check
      credential_ids = vertex_targets(@ai_package).map { |target| target[:credential].id }.uniq

      if credential_ids.empty?
        return redirect_to admin_ai_package_path(@ai_package),
                           alert: t('flash.admin.ai_packages.vertex_check_unsupported')
      end

      credential_ids.each do |id|
        Lalabase::Llm::VertexAvailabilityProbe.call(credential_id: id, force_refresh: true)
      end
      redirect_to admin_ai_package_path(@ai_package), notice: t('flash.admin.ai_packages.vertex_checked')
    rescue Lalabase::Llm::VertexAvailabilityProbe::ProbeError, Lalabase::Llm::Provider::Error => e
      redirect_to admin_ai_package_path(@ai_package),
                  alert: t('flash.admin.ai_packages.vertex_check_error', error: e.message)
    end

    private

    def set_ai_package
      @ai_package = AiPackage.includes(:embedding_credential, tiers: :chat_credential).find(params[:id])
    end

    # Uniqueness is enforced by a DB index (ai_packages.name,
    # ai_package_tiers[ai_package_id, key]), and an index reports by RAISING
    # from inside the INSERT — a validation cannot see the concurrent writer.
    # Catching it here turns the race into the same 422 the operator would have
    # got a second earlier, instead of a 500 that eats the whole form.
    def save_package(package)
      yield if block_given?
      package.save
    rescue ActiveRecord::RecordNotUnique
      package.errors.add(:base, :not_unique_race)
      false
    end

    # :kind is deliberately absent — see #create. tiers_attributes carries
    # STATIC child indexes (0/1, §7b.1 option C): permit silently drops
    # non-integer keys, which is what makes dynamically added rows vanish
    # without a trace. Fixed slots sidestep that trap constructively.
    #
    # :key and :label are NOT permitted. They are a product decision (E2), the
    # form renders them read-only, and the model header says so — but hidden
    # fields are client data, so "read-only" held only for people who use the
    # form as intended. #derive_tier_identity re-derives both server-side from
    # the slot index, which removes the tampering surface AND the duplicate-key
    # INSERT crash at the root rather than validating against it afterwards.
    def ai_package_params
      permitted = params.require(:ai_package).permit(
        :name, :description, :jurisdiction, :processing_region, :provider_note,
        :embedding_credential_id, :embedding_model, :embedding_dims,
        :active, :position,
        tiers_attributes: %i[id chat_credential_id chat_model]
      )
      derive_tier_identity(permitted)
    end

    # The slot index IS the rung: slot 0 is AiPackageTier::KEYS.first, and so on.
    # An index outside the fixed ladder is not a rung the form can render, so it
    # is dropped rather than guessed at.
    def derive_tier_identity(permitted)
      attributes = permitted[:tiers_attributes]
      return permitted if attributes.blank?

      # ActionController::Parameters is not an Enumerable — #to_h on a permitted
      # instance is what hands back a plain Hash to work on.
      derived = attributes.to_h.each_with_object({}) do |(index, tier), result|
        key = AiPackageTier::KEYS[index.to_i]
        next if key.nil?

        result[index] = tier.merge('key' => key,
                                   'label' => AiPackageTier::DEFAULT_LABELS.fetch(key),
                                   'position' => index.to_i)
      end
      permitted[:tiers_attributes] = derived
      permitted
    end

    # The form renders exactly AiPackageTier::KEYS as fixed blocks, so a legacy
    # row carrying only one rung stays EDITABLE: the missing slot is built here
    # and shows up in the form.
    #
    # It does not silently complete the ladder, though — the built slot has no
    # chat_credential, and AiPackageTier requires one. Submitting the form
    # without filling that slot therefore returns 422 naming the empty rung,
    # which is the honest outcome: a half-configured ladder must not become a
    # published package by accident. (An earlier version of this comment claimed
    # the save completes the ladder; it never did.)
    def build_missing_tiers(package)
      AiPackageTier::KEYS.each_with_index do |key, index|
        next if package.tiers.any? { |tier| tier.key.to_s == key }

        package.tiers.build(key: key, label: AiPackageTier::DEFAULT_LABELS.fetch(key), position: index)
      end
    end

    def load_credential_choices
      @embedding_credentials = AiCredential.enabled
                                           .where(purpose: AiCredentialPricing::EMBEDDING_PURPOSES,
                                                  provider: AiCredential.embedding_capable_providers)
                                           .order(:provider, :name)
      # Deliberately NOT narrowed by the embedding credential's provider
      # (§9 Falle 2): a Claude package with a Mistral embedding is the normal
      # case this form is built for, not an edge case to be prevented.
      @chat_credentials = AiCredential.enabled
                                      .where(purpose: AiCredentialPricing::CHAT_PURPOSES)
                                      .order(:provider, :name)
    end

    # "Mistral (EU) · openai_compatible · eu" — display_name over the generic
    # routing key. After P0 three EU credentials all sit on provider
    # openai_compatible, so an option text showing only the provider would be
    # unusable (§7b.1).
    def ai_credential_option_label(credential)
      [credential.display_label, credential.provider, credential.region.presence].compact.join(' · ')
    end

    # Every google credential the package references, with the model that would
    # ACTUALLY be called — the same resolution the save-time validations judge,
    # so page and validation can never disagree about which model is meant:
    # embedding_model verbatim (E11 — the package owns its triple and never
    # inherits credential.default_model), and per tier the model's own
    # #effective_chat_model (§6.1 precedence).
    def vertex_targets(package)
      targets = []

      if vertex_credential?(package.embedding_credential)
        targets << { slot: :embedding, tier_label: nil,
                     credential: package.embedding_credential,
                     model: package.embedding_model.to_s }
      end

      package.tiers.each do |tier|
        next unless vertex_credential?(tier.chat_credential)

        targets << { slot: :tier, tier_label: tier.label,
                     credential: tier.chat_credential,
                     model: tier.effective_chat_model.to_s }
      end

      targets
    end

    def vertex_credential?(credential)
      credential.present? && credential.provider == AiPackage::FOREIGN_PROVIDER_IN_EU
    end

    # Reads the probe cache per referenced google credential and picks the ONE
    # cell that matters (this package's model × the credential's region). No
    # cache, no matching cell or a non-404 error status all collapse to
    # :unknown — the honest "not verified" state, never a green claim.
    def vertex_checks_for(package)
      vertex_targets(package).map do |target|
        region = target[:credential].additional_config&.dig('location').to_s
        matrix = Lalabase::Llm::VertexAvailabilityProbe.cached_for(credential: target[:credential])
        cell = matrix && matrix[:results].find { |r| r[:region] == region && r[:model] == target[:model] }

        target.merge(region: region, state: vertex_state(cell), status_code: cell && cell[:status_code],
                     checked_at: matrix && matrix[:checked_at])
      end
    end

    # DELIBERATE DUPLICATION of the traffic-light rule in
    # app/views/admin/ai_credentials/_vertex_availability.html.erb (green =
    # available, red = 404, yellow = everything else). Not shared, because the
    # two surfaces answer different questions: the credential partial renders
    # the full region × model MATRIX from @vertex_availability and takes no
    # locals, while this one picks the SINGLE cell a package actually uses. A
    # third caller of this rule is the moment to extract it — until then, keep
    # both sides in step by hand.
    def vertex_state(cell)
      return :unknown if cell.nil?
      return :available if cell[:available]
      return :unavailable if cell[:status_code] == 404

      :unknown
    end
  end
end
