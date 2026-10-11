# frozen_string_literal: true

module Users
  class PersonalAccessTokensController < ApplicationController
    before_action :authenticate_user!
    skip_before_action :load_tenant_from_session
    before_action :set_token, only: %i[edit update destroy]

    EXPIRY_PRESETS = {
      '7' => 7.days,
      '30' => 30.days,
      '60' => 60.days,
      '90' => PersonalAccessToken::MAX_LIFETIME
    }.freeze

    # GET /users/personal_access_tokens
    def index
      authorize PersonalAccessToken
      @tokens = policy_scope(PersonalAccessToken)
                .includes(
                  personal_access_token_organisations: :organisation,
                  personal_access_token_projects: :project
                )
                .order(created_at: :desc)
    end

    # GET /users/personal_access_tokens/new
    def new
      @token = current_user.personal_access_tokens.new(expires_at: 30.days.from_now)
      authorize @token
      load_form_collections
    end

    # POST /users/personal_access_tokens
    #
    # Asks for the current password, like the data export: a token outlives the
    # session it was made in, so a hijacked session must not mint one.
    def create
      @token = current_user.personal_access_tokens.new(create_params)
      @token.expires_at = resolve_expires_at(params[:personal_access_token])
      apply_scope_selections(@token, params[:personal_access_token])
      @token.assign_token!
      authorize @token

      unless current_user.valid_password?(params[:current_password].to_s)
        load_form_collections
        flash.now[:alert] = t('views.users.personal_access_tokens.create.wrong_password')
        render :new, status: :unprocessable_content
        return
      end

      if @token.save
        @plaintext_token = @token.token
        # Inline render — no redirect, so the plaintext is not retained on a browser reload.
        render :created
      else
        load_form_collections
        flash.now[:alert] = @token.errors.full_messages.first
        render :new, status: :unprocessable_content
      end
    end

    # GET /users/personal_access_tokens/:id/edit
    def edit; end

    # PATCH /users/personal_access_tokens/:id
    def update
      if @token.update(update_params)
        redirect_to users_personal_access_tokens_path,
                    notice: t('views.users.personal_access_tokens.update.success')
      else
        flash.now[:alert] = @token.errors.full_messages.first
        render :edit, status: :unprocessable_entity
      end
    end

    # DELETE /users/personal_access_tokens/:id
    def destroy
      @token.revoke!
      redirect_to users_personal_access_tokens_path,
                  notice: t('views.users.personal_access_tokens.destroy.success')
    end

    private

    def set_token
      @token = current_user.personal_access_tokens.find(params[:id])
      authorize @token
    end

    def create_params
      params.require(:personal_access_token).permit(:name, :read_only)
    end

    def update_params
      # name + read_only are editable. read_only lets an owner flip an existing
      # token to writable without re-creating it (which would change the secret).
      params.require(:personal_access_token).permit(:name, :read_only)
    end

    # A custom date beyond PersonalAccessToken::MAX_LIFETIME is passed through
    # as typed: the model refuses it with a message, rather than this method
    # quietly shortening what the person asked for.
    def resolve_expires_at(attrs)
      preset = attrs&.dig(:expires_preset)
      if preset == 'custom' && attrs[:expires_at].present?
        begin
          return Time.zone.parse(attrs[:expires_at])
        rescue StandardError
          30.days.from_now
        end
      end

      EXPIRY_PRESETS.fetch(preset, 30.days).from_now
    end

    # Reads the selected orgs + (per org) projects from the form params
    # and builds the corresponding scope links on the unsaved token.
    # organisation_mode "all" sets all_organisations and builds NO links: a box
    # still ticked from before the switch must not give the token a second meaning
    # (the model refuses links next to the option).
    def apply_scope_selections(token, attrs)
      return if attrs.blank?

      if attrs[:organisation_mode] == 'all'
        token.all_organisations = true
        return
      end

      selected_org_ids = Array(attrs[:organisation_ids]).reject(&:blank?)
      project_modes    = attrs[:project_mode] || {}      # { org_id => "all" | "selected" }
      selected_project_ids = attrs[:project_ids] || {}   # { org_id => [project_id, ...] }

      # Active memberships only: an inactive one keeps the organisation in
      # current_user.organisations, but must not become a token scope.
      accessible_orgs = current_user.active_organisations.where(id: selected_org_ids).index_by { |o| o.id.to_s }

      selected_org_ids.each do |org_id|
        org = accessible_orgs[org_id]
        next unless org

        mode = project_modes[org_id] || 'all'
        all_projects = (mode != 'selected')

        token.personal_access_token_organisations.build(
          organisation: org,
          all_projects: all_projects
        )

        next if all_projects

        project_ids = Array(selected_project_ids[org_id]).reject(&:blank?)
        accessible_projects = ActsAsTenant.with_tenant(org) do
          policy_scope_user_projects(org).where(id: project_ids)
        end
        accessible_projects.each do |project|
          token.personal_access_token_projects.build(project: project)
        end
      end
    end

    def policy_scope_user_projects(org)
      ActsAsTenant.with_tenant(org) { Pundit.policy_scope(current_user, Project) }
    end

    # The organisation choice survives a form that comes back with an error; anything but
    # "all" is the default "selected".
    def load_form_collections
      @organisation_mode = params.dig(:personal_access_token, :organisation_mode) == 'all' ? 'all' : 'selected'
      @user_organisations = current_user.active_organisations.order(:name).to_a
      @projects_by_organisation = @user_organisations.index_with do |org|
        ActsAsTenant.with_tenant(org) do
          policy_scope_user_projects(org).order(:name).to_a
        end
      end
    end
  end
end
