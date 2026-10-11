# frozen_string_literal: true

module Organisations
  # In-app per-org persona management (account-admin, Pundit-gated via
  # PromptPersonaPolicy — see RolesController for the same shape). An org curates
  # its OWN personas; in the chat picker an org row overrides the global row of the
  # same key (prefer_org_owned). The global pool itself is operator territory
  # (Admin::PromptPersonasController) and is shown here read-only as override
  # templates.
  class PromptPersonasController < Organisations::BaseController
    before_action :set_prompt_persona, only: %i[edit update destroy]

    def index
      authorize PromptPersona
      # policy_scope == available_for(org): the org's own rows + the global pool,
      # active only (also satisfies BaseController's verify_policy_scoped). Split
      # into the editable own list and the read-only global templates. Per-org
      # personas are always active (no toggle in-app), so none are hidden here.
      pool = policy_scope(PromptPersona).to_a
      @org_personas    = pool.select { |persona| persona.organisation_id == current_organisation.id }
      @global_personas = pool.select { |persona| persona.organisation_id.nil? }
      @overridden_keys = @org_personas.map(&:key)
    end

    def new
      @prompt_persona = build_persona
      authorize @prompt_persona
    end

    def create
      @prompt_persona = current_organisation.prompt_personas.new(prompt_persona_params)
      # Invariant: per-org personas are NEVER system. A system per-org row would
      # make prevent_system_destroy block BOTH its own deletion and the org's
      # deletion (the dependent: :destroy cascade). Forced here, never from params.
      @prompt_persona.system = false
      authorize @prompt_persona

      if @prompt_persona.save
        redirect_to organisation_prompt_personas_path(current_organisation), notice: t('flash.prompt_personas.created')
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @prompt_persona
    end

    def update
      authorize @prompt_persona

      if @prompt_persona.update(prompt_persona_params)
        redirect_to organisation_prompt_personas_path(current_organisation), notice: t('flash.prompt_personas.updated')
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      authorize @prompt_persona
      @prompt_persona.destroy
      redirect_to organisation_prompt_personas_path(current_organisation), notice: t('flash.prompt_personas.deleted')
    end

    private

    # Scope the lookup to the org so a global id or another org's id 404s before
    # reaching authorize — defense in depth on top of the policy's org_owned? check.
    def set_prompt_persona
      @prompt_persona = current_organisation.prompt_personas.find(params[:id])
    end

    # ?from=<key> prefills a new persona from a GLOBAL template (the "create
    # override" flow); without it, a blank persona. The find is scoped to
    # organisation_id: nil ON PURPOSE — only the global pool is a valid template,
    # never another org's row — so a bad or foreign key simply yields a blank form.
    # Built on the org association so organisation_id is set for both authorize and
    # the form's URL.
    def build_persona
      attrs = {}
      if params[:from].present?
        template = PromptPersona.find_by(organisation_id: nil, key: params[:from])
        attrs = template.slice(:key, :labels, :prompt_fragments, :position) if template
      end
      current_organisation.prompt_personas.new(attrs)
    end

    # No :active and no :system — per-org personas are always active and never
    # system (see create). :organisation_id is set by the association, not params.
    def prompt_persona_params
      params.require(:prompt_persona).permit(
        :key, :position,
        labels: Lalabase::Languages::SUPPORTED,
        prompt_fragments: Lalabase::Languages::SUPPORTED
      )
    end
  end
end
