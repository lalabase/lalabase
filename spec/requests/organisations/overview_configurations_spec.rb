# frozen_string_literal: true

require 'rails_helper'

# What:  Organisation-overview configuration save (PATCH) + edit (GET) + preview/reset request paths.
# Type:  Request specs (full stack: auth, the two org save scopes, frame-only 422, permission-gated
#        picker).
# Why:   The overview reuses the SHARED editor orchestration (Dashboards::Configurable) + the SHARED
#        editor body, bound to the org surface. What is overview-SPECIFIC and pinned here: only two
#        save scopes (personal / org-default, no cross-project "_all"); the org-default scope is
#        admin-only and drops the acting admin's own override; the picker is gated by the org "access
#        in ANY project" primitive (not a single-project policy); and the frame-only 422 re-render
#        carries the overview frame AND a working briefing (so the rejected widgets still preview).
RSpec.describe 'Organisations::OverviewConfigurations', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: 'account_admin') }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }

  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  let!(:member_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member, organisation: organisation, role: member_role, active: true)
    end
  end

  # org_activity_feed + projects_table both have permission: nil → available to every member without
  # any project access, so the save/preview paths need no permission scaffolding.
  let(:layout_params) do
    { rows: { '0' => { widgets: { '0' => { key: 'org_activity_feed' } } } } }
  end

  before { ActsAsTenant.current_tenant = organisation }

  # OverviewConfiguration without tenant restriction (counts the org-default user_id NULL rows too).
  def config_count
    ActsAsTenant.without_tenant { OverviewConfiguration.count }
  end

  describe 'PATCH #update' do
    context 'as a member (personal scope)' do
      before { sign_in member }

      it 'saves the personal overview by default (no scope param)' do
        patch organisation_overview_configuration_path(organisation), params: layout_params

        expect(response).to redirect_to(organisation_root_path(organisation))
        expect(flash[:notice]).to eq(I18n.t('overview.configuration.saved'))
        ActsAsTenant.with_tenant(organisation) do
          config = OverviewConfiguration.find_by(user: member)
          expect(config).to be_present
          expect(config.layout.first['widgets'].first['key']).to eq('org_activity_feed')
          expect(OverviewConfiguration.find_by(user: nil)).to be_nil
        end
      end

      it 'persists a whitelisted item limit for org_activity_feed' do
        params = { rows: { '0' => { widgets: { '0' => { key: 'org_activity_feed', limit: '15' } } } } }
        patch organisation_overview_configuration_path(organisation), params: params

        ActsAsTenant.with_tenant(organisation) do
          widget = OverviewConfiguration.find_by(user: member).layout.first['widgets'].first
          expect(widget['limit']).to eq(15)
        end
      end

      it 'persists the projects_table selection mode and project ids' do
        project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
        params = { rows: { '0' => { widgets: { '0' => { key: 'projects_table', mode: 'selected', project_ids: [project.id] } } } } }
        patch organisation_overview_configuration_path(organisation), params: params

        ActsAsTenant.with_tenant(organisation) do
          widget = OverviewConfiguration.find_by(user: member).layout.first['widgets'].first
          expect(widget['mode']).to eq('selected')
          expect(widget['project_ids']).to eq([project.id])
        end
      end

      # End-to-end connected block: HTTP form -> editor parse (registry whitelist) -> DB. The save path
      # uses the FULL registry (not permission-filtered), so a member can drive it. Pins that a forged
      # stage and the submitted order can never survive into storage.
      it 'persists billing_overview stage_keys whitelisted and in canonical order, dropping bogus' do
        params = { rows: { '0' => { widgets: { '0' => { key: 'billing_overview', stage_keys: %w[billed bogus without_billing] } } } } }
        patch organisation_overview_configuration_path(organisation), params: params

        ActsAsTenant.with_tenant(organisation) do
          widget = OverviewConfiguration.find_by(user: member).layout.first['widgets'].first
          expect(widget['stage_keys']).to eq(%w[without_billing billed])
        end
      end

      it 'stores no stage_keys when all submitted billing stages are bogus (falls back to all stages)' do
        params = { rows: { '0' => { widgets: { '0' => { key: 'billing_overview', stage_keys: %w[bogus evil] } } } } }
        patch organisation_overview_configuration_path(organisation), params: params

        ActsAsTenant.with_tenant(organisation) do
          widget = OverviewConfiguration.find_by(user: member).layout.first['widgets'].first
          expect(widget).to eq('key' => 'billing_overview')
        end
      end

      it 'downgrades the admin-only default scope to a personal save' do
        patch organisation_overview_configuration_path(organisation), params: layout_params.merge(save_scope: 'default')

        ActsAsTenant.with_tenant(organisation) do
          expect(OverviewConfiguration.find_by(user: nil)).to be_nil
          expect(OverviewConfiguration.find_by(user: member)).to be_present
        end
      end

      it 'falls back to a personal save for an unknown/forged save_scope' do
        # The loop replays the same query shape across scopes -> Prosopite flags a false N+1.
        Prosopite.pause
        begin
          ['bogus', 'default_evil', ''].each do |bad_scope|
            ActsAsTenant.with_tenant(organisation) { OverviewConfiguration.delete_all }
            patch organisation_overview_configuration_path(organisation), params: layout_params.merge(save_scope: bad_scope)

            ActsAsTenant.with_tenant(organisation) do
              expect(OverviewConfiguration.find_by(user: nil)).to be_nil, "#{bad_scope.inspect} must not write the org default"
              expect(OverviewConfiguration.find_by(user: member)).to be_present
            end
          end
        ensure
          Prosopite.resume
        end
      end
    end

    context 'as an admin (org-default scope)' do
      before { sign_in admin }

      it 'saves the shared org default (user_id NULL)' do
        patch organisation_overview_configuration_path(organisation), params: layout_params.merge(save_scope: 'default')

        expect(response).to redirect_to(organisation_root_path(organisation))
        expect(flash[:notice]).to eq(I18n.t('overview.configuration.saved_as_default'))
        ActsAsTenant.with_tenant(organisation) do
          config = OverviewConfiguration.find_by(user: nil)
          expect(config).to be_present
          expect(config.layout.first['widgets'].first['key']).to eq('org_activity_feed')
        end
      end

      # The cascade prefers a personal config, so a leftover personal override would hide the freshly
      # saved org default from the admin. Saving the default drops the admin's OWN override only.
      it 'drops the acting admin own personal override but keeps other members configs' do
        ActsAsTenant.with_tenant(organisation) do
          create(:overview_configuration, user: admin, organisation: organisation,
                                          layout: [{ 'widgets' => [{ 'key' => 'projects_table' }] }])
          create(:overview_configuration, user: member, organisation: organisation,
                                          layout: [{ 'widgets' => [{ 'key' => 'projects_table' }] }])
        end

        patch organisation_overview_configuration_path(organisation), params: layout_params.merge(save_scope: 'default')

        ActsAsTenant.with_tenant(organisation) do
          expect(OverviewConfiguration.find_by(user: admin)).to be_nil
          expect(OverviewConfiguration.find_by(user: nil)).to be_present
          expect(OverviewConfiguration.find_by(user: member)).to be_present
        end
      end
    end

    context 'authentication' do
      it 'redirects unauthenticated users' do
        patch organisation_overview_configuration_path(organisation), params: layout_params
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # A validation failure must re-render the #overview frame ONLY (HTTP 422, layout: false) carrying the
  # in-progress (rejected) layout — not navigate away, not strip the work, not emit app chrome.
  describe 'PATCH #update validation failure (frame-only 422)' do
    before { sign_in member }

    it 'refuses an empty layout with a frame-only 422 and persists nothing' do
      patch organisation_overview_configuration_path(organisation), params: {}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('<turbo-frame id="overview"')
      expect(response.body).not_to include('<html')
      expect(response.body).to include(
        ERB::Util.html_escape(
          I18n.t('activerecord.errors.models.overview_configuration.attributes.layout.empty_not_allowed')
        )
      )

      ActsAsTenant.with_tenant(organisation) do
        expect(OverviewConfiguration.find_by(user: member)).to be_nil
      end
    end

    # Over-full row (org_activity_feed 4 + projects_table 4 = 8 > 6): both widgets still render in the
    # 422 frame, which proves @briefing is wired into the re-render path (the previews need it).
    it 'rejects an over-full row with a 422 frame that still previews the rejected widgets' do
      params = { rows: { '0' => { widgets: { '0' => { key: 'org_activity_feed', units: '4' },
                                             '1' => { key: 'projects_table', units: '4' } } } } }

      patch organisation_overview_configuration_path(organisation), params: params

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('<turbo-frame id="overview"')
      expect(response.body).to include('data-widget-key="org_activity_feed"')
      expect(response.body).to include('data-widget-key="projects_table"')
      ActsAsTenant.with_tenant(organisation) do
        expect(OverviewConfiguration.find_by(user: member)).to be_nil
      end
    end
  end

  describe 'GET #edit' do
    context 'as a member' do
      before { sign_in member }

      it 'renders the editor with the personal scope but hides the admin default scope' do
        get edit_organisation_overview_configuration_path(organisation)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('dashboard.configuration.add_widget'))
        expect(response.body).to include('value="personal"')
        expect(response.body).not_to include('value="default"')
      end

      # The picker is gated by the org "access in ANY project" primitive: a member with no project
      # access still gets the permission-free widgets but NOT the time-tracking ones.
      it 'offers permission-free widgets but gates the time-tracking widgets' do
        get edit_organisation_overview_configuration_path(organisation)

        expect(response.body).to include('data-widget-template="org_activity_feed"')
        expect(response.body).not_to include('data-widget-template="my_week_stats"')
      end

      # The projects_table widget now carries a settings form (selection mode); its template must
      # render the mode picker + the (hidden until "selected") project list container.
      it 'renders the projects_table selection-mode settings' do
        get edit_organisation_overview_configuration_path(organisation)

        expect(response.body).to include('data-project-selection')
        expect(response.body).to include(I18n.t('overview.configuration.projects_table.mode_pinned'))
      end
    end

    context 'as an admin' do
      before { sign_in admin }

      it 'offers the org-default scope and every widget (admin sees all projects)' do
        get edit_organisation_overview_configuration_path(organisation)

        expect(response.body).to include('value="personal"')
        expect(response.body).to include('value="default"')
        expect(response.body).to include('data-widget-template="my_week_stats"')
      end

      # The billing_overview slot in the default layout must render its stage picker (the registry
      # :extra_params drives has_settings, which renders the _widget_settings billing branch). The
      # [stage_keys][] suffix is exactly what the JS empty-card guard watches.
      it 'renders the billing_overview stage picker in the editor settings' do
        get edit_organisation_overview_configuration_path(organisation)

        expect(response.body).to include('[stage_keys][]')
      end

      # The projects_table "selected projects" picker lists the viewer's accessible projects as
      # checkboxes (the [project_ids][] field only renders when at least one project is selectable).
      it 'lists accessible projects as checkboxes in the projects_table picker' do
        project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
        get edit_organisation_overview_configuration_path(organisation)

        expect(response.body).to include('[project_ids][]')
        expect(response.body).to include("value=\"#{project.id}\"")
      end

      it "never lists another organisation's project in the picker (cross-tenant isolation)" do
        own = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
        foreign_org = create(:organisation)
        foreign = ActsAsTenant.with_tenant(foreign_org) { create(:project, organisation: foreign_org) }

        get edit_organisation_overview_configuration_path(organisation)

        expect(response.body).to include("value=\"#{own.id}\"")
        expect(response.body).not_to include(foreign.id)
      end
    end
  end

  # Persisted projects_table settings must round-trip into the editor markup: the saved mode
  # pre-checks its radio, the picker is shown only for "selected", and the saved project_ids are
  # pre-checked. Scoped to the LIVE slot (inside the rows container) so the hidden <template> clones
  # — which always render the modeless default — never satisfy the assertions.
  describe 'GET #edit — persisted projects_table settings round-trip' do
    # The single projects_table slot in the live layout (NOT the add-widget <template> at the root).
    def live_projects_table_slot(body)
      rows = Nokogiri::HTML(body).at_css('[data-dashboard-inline-edit-target="rows"]')
      rows&.css('[data-widget-key="projects_table"]')&.first
    end

    def saved_layout(viewer, layout)
      ActsAsTenant.with_tenant(organisation) do
        create(:overview_configuration, user: viewer, organisation: organisation, layout: layout)
      end
    end

    context 'as a member (mode-only, no project access needed)' do
      before { sign_in member }

      it 'pre-selects "all" for the modeless default layout' do
        get edit_organisation_overview_configuration_path(organisation)
        checked = live_projects_table_slot(response.body).at_css('input[type="radio"][checked]')
        expect(checked['value']).to eq('all')
      end

      # The radio group is derived from the single EDITOR_MODES source: every mode renders (in order)
      # with a translated label. Adding a mode to the constant without an i18n key turns this red.
      it 'renders exactly the EDITOR_MODES radios, each with a translated label' do
        get edit_organisation_overview_configuration_path(organisation)
        slot = live_projects_table_slot(response.body)

        values = slot.css('input[type="radio"][name*="[mode]"]').map { |r| r['value'] }
        expect(values).to eq(Overview::ProjectsTableComponent::EDITOR_MODES)

        Overview::ProjectsTableComponent::EDITOR_MODES.each do |mode|
          label = I18n.t("overview.configuration.projects_table.mode_#{mode}")
          expect(label).not_to match(/translation missing/i)
          expect(slot.text).to include(label)
        end
      end

      it 'pre-selects the saved mode radio' do
        saved_layout(member, [{ 'widgets' => [{ 'key' => 'projects_table', 'mode' => 'pinned' }] }])
        get edit_organisation_overview_configuration_path(organisation)
        checked = live_projects_table_slot(response.body).at_css('input[type="radio"][checked]')
        expect(checked['value']).to eq('pinned')
      end

      it 'hides the project picker unless the saved mode is "selected"' do
        get edit_organisation_overview_configuration_path(organisation) # default -> all
        default_picker = live_projects_table_slot(response.body).at_css('[data-project-selection]')
        expect(default_picker['hidden']).not_to be_nil

        saved_layout(member, [{ 'widgets' => [{ 'key' => 'projects_table', 'mode' => 'selected' }] }])
        get edit_organisation_overview_configuration_path(organisation)
        selected_picker = live_projects_table_slot(response.body).at_css('[data-project-selection]')
        expect(selected_picker['hidden']).to be_nil
      end

      it 'shows the no-projects hint and no checkboxes when the viewer has no project access' do
        ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
        get edit_organisation_overview_configuration_path(organisation)
        slot = live_projects_table_slot(response.body)
        expect(slot.css('input[type="checkbox"]')).to be_empty
        expect(slot.text).to include(I18n.t('overview.configuration.projects_table.no_projects'))
      end
    end

    context 'as an admin (project_ids pre-check)' do
      before { sign_in admin }

      it 'checks exactly the saved project_ids, leaving the rest unchecked' do
        p1, p2 = ActsAsTenant.with_tenant(organisation) do
          [create(:project, organisation: organisation), create(:project, organisation: organisation)]
        end
        saved_layout(admin, [{ 'widgets' => [{ 'key' => 'projects_table', 'mode' => 'selected', 'project_ids' => [p1.id] }] }])

        get edit_organisation_overview_configuration_path(organisation)
        slot = live_projects_table_slot(response.body)
        checked = slot.css('input[type="checkbox"][checked]').map { |cb| cb['value'] }
        all_boxes = slot.css('input[type="checkbox"]').map { |cb| cb['value'] }

        expect(checked).to eq([p1.id])
        expect(all_boxes).to include(p1.id, p2.id) # both offered, only p1 checked
      end
    end
  end

  # The live-preview endpoint returns a layout-free fragment for one widget with its unsaved settings.
  describe 'POST #widget_preview' do
    before { sign_in member }

    it 'renders the live component for a permission-free widget, layout-free' do
      post widget_preview_organisation_overview_configuration_path(organisation),
           params: { widget: { key: 'org_activity_feed', limit: '10' } }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('pointer-events-none') # the live-component branch of _widget_preview
      expect(response.body).not_to include('<html')           # fragment only, no app chrome
    end

    # The whole preview path for the new setting: widget[mode] -> build_widget(parse) ->
    # component_for_widget(extra_params) -> render. With "with_entries" and no entries the mode-specific
    # empty state proves the submitted mode actually reached and filtered the component.
    it 'applies the submitted projects_table mode in the live preview' do
      post widget_preview_organisation_overview_configuration_path(organisation),
           params: { widget: { key: 'projects_table', mode: 'with_entries' } }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('dashboard.briefing.sections.projects.empty_with_entries'))
      expect(response.body).not_to include('<html')
    end
  end

  # Reset deletes the user's OWN overview so it falls back to the org/system default.
  describe 'DELETE #reset' do
    before { sign_in member }

    it "destroys the user's overview and redirects to the org root" do
      ActsAsTenant.with_tenant(organisation) do
        create(:overview_configuration, user: member, organisation: organisation,
                                        layout: [{ 'widgets' => [{ 'key' => 'projects_table' }] }])
      end

      delete reset_organisation_overview_configuration_path(organisation)

      expect(response).to redirect_to(organisation_root_path(organisation))
      ActsAsTenant.with_tenant(organisation) do
        expect(OverviewConfiguration.find_by(user: member)).to be_nil
      end
    end
  end
end
