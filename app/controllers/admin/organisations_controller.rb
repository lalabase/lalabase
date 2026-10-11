# frozen_string_literal: true

module Admin
  class OrganisationsController < Admin::ApplicationController
    # before_action :check_permission

    def index
      # No :ai_usages preload — the index view doesn't read it, and since S3 writes an
      # ai_usages row per AI action, preloading ALL of them for ALL orgs would grow
      # unbounded. The per-provider stats below come from their own aggregate query.
      #
      # The package chain IS preloaded: the "genutzte KI" column resolves the rung
      # per row, which without it is three queries per org (package → tiers →
      # credential) — the N+1 lesson from #368, on a page that lists every org.
      @organisations = Admin::Organisation
                       .includes(:memberships, ai_package: { tiers: :chat_credential })
                       .order(:created_at)
      # Resolved ONCE per org and reused by the rows AND the stats card, so the
      # number in the card and the badge in the row can never tell different
      # stories about the same organisation.
      @ai_routing_by_org_id = @organisations.index_by(&:id)
                                            .transform_values { |org| Admin::AiRoutingSummary.for(org) }
      @ai_stats = build_ai_stats
    end

    # GET /admin/organisations/:id
    # KI-Kontingent-Pflege (S3): per-org budget/buffer overrides + Nachweis-Historie.
    # Loads the PLAIN ::Organisation (the tenant ROOT is tenant-independent, like
    # ::Account) so ai_quota_ledger + AiUsage.quota_counted work unchanged here.
    def show
      @organisation = ::Organisation.find(params[:id])
      # ONE ledger for both quota partials, same reason the customer-facing usage page
      # builds one: each partial otherwise creates its own, and each of those re-runs
      # the monthly consumption sum plus two uncached SystemSetting reads. This is the
      # only other page in the app that renders both — the admin twin of a defect fixed
      # on the tenant side is the classic way half a fix ships.
      @ai_quota_ledger = @organisation.ai_quota_ledger
      load_ai_routing
    end

    # PATCH /admin/organisations/:id
    def update
      @organisation = ::Organisation.find(params[:id])
      # Compare the HARD LIMIT (budget + buffer), not just the budget: raising ONLY
      # the buffer also un-gates the org, so it must trigger the resume too.
      old_hard_limit = @organisation.ai_quota_ledger.hard_limit

      if @organisation.update(quota_params)
        # Resume hook (decision 5A): a RAISED effective limit re-drives paused embeddings.
        AiQuotaResumeJob.perform_later(@organisation) if @organisation.ai_quota_ledger.hard_limit > old_hard_limit
        redirect_to admin_organisation_path(@organisation),
                    notice: t('flash.admin.organisations.quota_updated', name: @organisation.name)
      else
        load_ai_routing
        render :show, status: :unprocessable_entity
      end
    end

    # GET /admin/organisations/:id/roles
    # Returns a turbo frame with role select for the given organisation.
    # Used by the admin user creation form to dynamically load roles.
    def roles
      @organisation = Admin::Organisation.find(params[:id])
      @roles = @organisation.roles.ordered_by_title

      render partial: 'admin/users/role_select', locals: { roles: @roles }
    end

    # PATCH /admin/organisations/:id/toggle_code_indexing
    # Operator switch for whether a connected repository is INDEXED at all (M10/D3).
    # It was called toggle_project_chat until step 4 of doc/projekt_chat_abbau_plan.md,
    # after the surface it was named for was gone. The admin area is beuser-gated
    # (Admin::Authentication), so org admins can't self-enable it.
    #
    # Release 2: the new column alone. Release 1 wrote both, because the read side ORed
    # them and a stale old column would have been undone by this very release. The
    # backfill has run (6 organisations, 31.08.2026), the old column is in
    # ignored_columns, and writing it now would raise.
    def toggle_code_indexing
      organisation = Admin::Organisation.find(params[:id])
      state = !organisation.code_indexing?
      organisation.update!(code_indexing_enabled: state)

      redirect_to admin_organisations_path,
                  notice: t('flash.admin.organisations.toggle_success',
                            name: organisation.name,
                            state: t(state ? 'code_indexing_on' : 'code_indexing_off',
                                     scope: 'admin.organisations.index'))
    end

    # PATCH /admin/organisations/:id/toggle_assistant
    # Operator switch for the per-org assistant (S3a, §13-2). Deliberately a
    # SEPARATE flag from code_indexing_enabled: an org may have its repositories
    # indexed without getting the assistant, and the other way round. Beuser-gated too.
    def toggle_assistant
      toggle_flag!(:assistant_enabled, label_prefix: 'assistant', flash_key: 'toggle_assistant_success')
    end

    # PATCH /admin/organisations/:id/toggle_data_import
    # Operator switch for the CodebaseHQ data import. It reads exactly one vendor's XML
    # export, so it stays off for every organisation until someone asks for it; the flag
    # is what CodebaseImportFilePolicy#import_permitted? reads.
    def toggle_data_import
      toggle_flag!(:data_import_enabled, label_prefix: 'data_import', flash_key: 'toggle_data_import_success')
    end

    private

    # The two lanes the detail page states about this org. They are asked
    # SEPARATELY because they route separately: chat resolves package rung >
    # BYOK > system credential, while the search lane must name the space that
    # SERVES queries — reading the configured lane would name the new provider
    # while the old one still receives every query during a staged switch.
    def load_ai_routing
      @ai_routing = Admin::AiRoutingSummary.for(@organisation)
      @disclosure = ::Lalabase::Llm::Factory.routing_disclosure(@organisation)
    end

    # Only the quota overrides are editable here (blank field → nil → SystemSetting
    # default; "0" → a hard cap). Nothing else about the org is admin-editable.
    def quota_params
      params.require(:organisation).permit(:ai_quota_credits_override, :ai_quota_buffer_override)
    end

    # Shared body of the per-org operator switches: flip the boolean, redirect back to
    # the list, name the RESULTING state in the flash. The state label is read from the
    # same index translations the column badge uses, so flash and badge can never tell
    # different stories about the same organisation.
    def toggle_flag!(attribute, label_prefix:, flash_key:)
      organisation = Admin::Organisation.find(params[:id])
      predicate = :"#{attribute}?"
      organisation.update!(attribute => !organisation.public_send(predicate))

      state_key = organisation.public_send(predicate) ? "#{label_prefix}_on" : "#{label_prefix}_off"
      redirect_to admin_organisations_path,
                  notice: t("flash.admin.organisations.#{flash_key}",
                            name: organisation.name,
                            state: t(state_key, scope: 'admin.organisations.index'))
    end

    # Counted off the RESOLVED routing, not off has_own_ai_credentials?: the
    # predicate answers "brought a token", which lumps curated package orgs in
    # with orgs on the plain system credential — two different recipients under
    # one number.
    def build_ai_stats
      sources = @ai_routing_by_org_id.values.map(&:source)
      {
        total_orgs: @organisations.count,
        with_own_credentials: sources.count(:byok),
        with_package: sources.count(:package),
        using_system_credentials: sources.count(:system),
        total_usage_30d: Admin::AiUsage.recent(30).sum(:tokens_used),
        total_cost_30d: Admin::AiUsage.recent(30).sum(:cost_cents)
      }
    end
  end
end
