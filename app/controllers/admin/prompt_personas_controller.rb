# frozen_string_literal: true

module Admin
  # Operator-curated GLOBAL persona pool (organisation_id NULL). Mirrors
  # Admin::AiCredentialsController: a cross-tenant, Beuser-gated resource (auth via
  # Admin::ApplicationController's Admin::Authentication include — NOT Pundit).
  # Per-org personas are managed by each org's account-admins in
  # Organisations::PromptPersonasController, never here.
  class PromptPersonasController < Admin::ApplicationController
    before_action :set_prompt_persona, only: %i[edit update destroy]

    # Only the global pool. Per-org rows belong to their own org's admins.
    def index
      @prompt_personas = PromptPersona.where(organisation_id: nil).order(:position, :key)
    end

    def new
      @prompt_persona = PromptPersona.new
    end

    def create
      @prompt_persona = PromptPersona.new(prompt_persona_params)
      # Forced, not taken from params: the operator backend only ever creates
      # GLOBAL, deletable personas. The protected system:true defaults are created
      # by db/seeds, never through this form.
      @prompt_persona.organisation_id = nil
      @prompt_persona.system = false

      if @prompt_persona.save
        redirect_to admin_prompt_personas_path, notice: t('flash.admin.prompt_personas.created')
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      if @prompt_persona.update(update_params)
        redirect_to admin_prompt_personas_path, notice: t('flash.admin.prompt_personas.updated')
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      # prevent_system_destroy aborts a system persona's destroy (returns false, no
      # exception). Surface that as a friendly alert instead of a 500.
      if @prompt_persona.destroy
        redirect_to admin_prompt_personas_path, notice: t('flash.admin.prompt_personas.deleted')
      else
        redirect_to admin_prompt_personas_path, alert: t('flash.admin.prompt_personas.delete_blocked')
      end
    end

    private

    def set_prompt_persona
      @prompt_persona = PromptPersona.find(params[:id])
    end

    # labels/prompt_fragments are jsonb hashes keyed by language; permitting the
    # supported-language list (not an open hash) keeps the input closed and ties it
    # to the single source of truth in Lalabase::Languages.
    def prompt_persona_params
      params.require(:prompt_persona).permit(
        :key, :position, :active,
        labels: Lalabase::Languages::SUPPORTED,
        prompt_fragments: Lalabase::Languages::SUPPORTED
      )
    end

    # A system persona's key is a contract (DEFAULT_KEY 'overview' is the
    # guaranteed fallback). Operators may edit its content, position and active
    # flag, but not rename it — so drop :key from the update for system rows.
    # (Deactivating the global default is additionally blocked at the model layer.)
    def update_params
      return prompt_persona_params unless @prompt_persona.system?

      prompt_persona_params.except(:key)
    end
  end
end
