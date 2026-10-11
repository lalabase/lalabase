# frozen_string_literal: true

require 'rails_helper'

# What:  Dashboard configuration save (PATCH) + edit (GET) request paths.
# Type:  Request specs (full stack: auth, policy, save paths, frame-only 422).
# Why:   Save persists the parsed layout per user / per project default / across all projects (admin
#        only). The auto-columns model stores rows as { widgets: [...] } with per-widget `units`; an
#        over-full row (Σ units > ROW_UNITS) or an empty layout is rejected with a frame-only 422 that
#        keeps the in-progress work. Permission gating + the no-access placeholder are pinned on GET.
RSpec.describe 'Organisations::DashboardConfigurations', type: :request do
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

  let!(:project_a) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Alpha') }
  end

  let!(:project_b) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Beta') }
  end

  let!(:project_c) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt Gamma') }
  end

  # Member needs project access for the show? policy
  let!(:member_permission_a) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: member, project: project_a, tickets_access: 'read_only')
    end
  end

  let(:layout_params) do
    { rows: { '0' => { widgets: { '0' => { key: 'stats_cards' } } } } }
  end

  before { ActsAsTenant.current_tenant = organisation }

  # Helper: counts DashboardConfigurations without tenant restriction
  def config_count
    ActsAsTenant.without_tenant { DashboardConfiguration.count }
  end

  describe 'PATCH #update' do
    context 'as admin' do
      before { sign_in admin }

      it 'saves user-specific config for current project (no checkboxes)' do
        patch organisation_project_dashboard_configuration_path(organisation, project_a), params: layout_params

        expect(response).to redirect_to(organisation_project_path(organisation, project_a))
        expect(flash[:notice]).to eq(I18n.t('dashboard.configuration.saved'))

        ActsAsTenant.with_tenant(organisation) do
          config = DashboardConfiguration.find_by(user: admin, project: project_a)
          expect(config).to be_present
          expect(config.layout.first['widgets'].first['key']).to eq('stats_cards')

          expect(DashboardConfiguration.find_by(user: admin, project: project_b)).to be_nil
        end
      end

      it 'saves as project default for current project (default_this)' do
        patch organisation_project_dashboard_configuration_path(organisation, project_a),
              params: layout_params.merge(save_scope: 'default_this')

        expect(response).to redirect_to(organisation_project_path(organisation, project_a))
        expect(flash[:notice]).to eq(I18n.t('dashboard.configuration.saved_as_default'))

        ActsAsTenant.with_tenant(organisation) do
          config = DashboardConfiguration.find_by(user: nil, project: project_a)
          expect(config).to be_present
          expect(config.layout.first['widgets'].first['key']).to eq('stats_cards')

          expect(DashboardConfiguration.find_by(user: nil, project: project_b)).to be_nil
        end
      end

      # personal_all is the destination the old two-checkbox UI could not express.
      it 'saves a personal config across all accessible projects (personal_all)' do
        Prosopite.pause
        begin
          before_count = config_count

          patch organisation_project_dashboard_configuration_path(organisation, project_a),
                params: layout_params.merge(save_scope: 'personal_all')

          expect(config_count - before_count).to eq(3)
          expect(flash[:notice]).to eq(I18n.t('dashboard.configuration.saved_personal_all', count: 3))

          ActsAsTenant.with_tenant(organisation) do
            [project_a, project_b, project_c].each do |project|
              config = DashboardConfiguration.find_by(user: admin, project: project)
              expect(config).to be_present
              expect(config.layout.first['widgets'].first['key']).to eq('stats_cards')
            end
            # personal_all must never write the shared project default
            expect(DashboardConfiguration.where(user: nil)).to be_empty
          end
        ensure
          Prosopite.resume
        end
      end

      # Upsert (not insert): personal_all must UPDATE an existing own row, not duplicate it. The
      # (user_id, project_id) unique index would otherwise raise RecordNotUnique. Kills a mutation
      # of `existing_configs[id] || new` to a bare `.new` in save_to_all_personal.
      it 'updates (not duplicates) an existing own config when saving personal_all' do
        ActsAsTenant.with_tenant(organisation) do
          DashboardConfiguration.create!(
            user: admin, project: project_b, organisation: organisation,
            layout: [{ 'type' => 'full', 'widgets' => [{ 'key' => 'notifications' }] }]
          )
        end

        before_count = config_count

        patch organisation_project_dashboard_configuration_path(organisation, project_a),
              params: layout_params.merge(save_scope: 'personal_all')

        expect(response).to redirect_to(organisation_project_path(organisation, project_a))
        # project_a + project_c new, project_b updated in place -> +2, not +3 (and no duplicate row)
        expect(config_count - before_count).to eq(2)

        ActsAsTenant.with_tenant(organisation) do
          rows_b = DashboardConfiguration.where(user: admin, project: project_b)
          expect(rows_b.count).to eq(1)
          expect(rows_b.first.layout.first['widgets'].first['key']).to eq('stats_cards')
        end
      end

      # resolve_layout prefers a personal row, so a leftover personal override would hide the
      # freshly saved default from the admin. Saving a default drops the admin's own override.
      it 'removes the acting admin own personal override for that project (default_this)' do
        ActsAsTenant.with_tenant(organisation) do
          DashboardConfiguration.create!(
            user: admin, project: project_a, organisation: organisation,
            layout: [{ 'type' => 'full', 'widgets' => [{ 'key' => 'notifications' }] }]
          )
          DashboardConfiguration.create!(
            user: admin, project: project_b, organisation: organisation,
            layout: [{ 'type' => 'full', 'widgets' => [{ 'key' => 'notifications' }] }]
          )
        end

        patch organisation_project_dashboard_configuration_path(organisation, project_a),
              params: layout_params.merge(save_scope: 'default_this')

        ActsAsTenant.with_tenant(organisation) do
          # Own override for the saved project is gone -> the new default shows through
          expect(DashboardConfiguration.find_by(user: admin, project: project_a)).to be_nil
          expect(DashboardConfiguration.find_by(user: nil, project: project_a)).to be_present
          # Override for a different project is untouched (only project_a was saved)
          expect(DashboardConfiguration.find_by(user: admin, project: project_b)).to be_present
        end
      end

      it 'never deletes other members personal layouts when saving a default' do
        ActsAsTenant.with_tenant(organisation) do
          DashboardConfiguration.create!(
            user: member, project: project_a, organisation: organisation,
            layout: [{ 'type' => 'full', 'widgets' => [{ 'key' => 'notifications' }] }]
          )
        end

        patch organisation_project_dashboard_configuration_path(organisation, project_a),
              params: layout_params.merge(save_scope: 'default_this')

        ActsAsTenant.with_tenant(organisation) do
          # The other member's personal customization must survive
          member_config = DashboardConfiguration.find_by(user: member, project: project_a)
          expect(member_config).to be_present
          expect(member_config.layout.first['widgets'].first['key']).to eq('notifications')
        end
      end

      describe 'default_all (project default for every project)' do
        it 'saves as project default for all projects' do
          # Per-project upsert loop -> per-project find_by below is intentional, not an N+1.
          Prosopite.pause
          begin
            before_count = config_count

            patch organisation_project_dashboard_configuration_path(organisation, project_a),
                  params: layout_params.merge(save_scope: 'default_all')

            expect(config_count - before_count).to eq(3)
            expect(response).to redirect_to(organisation_project_path(organisation, project_a))
            expect(flash[:notice]).to eq(I18n.t('dashboard.configuration.saved_as_default_all', count: 3))

            ActsAsTenant.with_tenant(organisation) do
              [project_a, project_b, project_c].each do |project|
                config = DashboardConfiguration.find_by(user: nil, project: project)
                expect(config).to be_present
                expect(config.layout.first['widgets'].first['key']).to eq('stats_cards')
              end
            end
          ensure
            Prosopite.resume
          end
        end

        it 'updates (not duplicates) existing project defaults' do
          ActsAsTenant.with_tenant(organisation) do
            DashboardConfiguration.create!(
              user: nil, project: project_b, organisation: organisation,
              layout: [{ 'widgets' => [{ 'key' => 'notifications' }] }]
            )
          end

          before_count = config_count

          patch organisation_project_dashboard_configuration_path(organisation, project_a),
                params: layout_params.merge(save_scope: 'default_all')

          # project_a + project_c new, project_b updated in place
          expect(config_count - before_count).to eq(2)

          ActsAsTenant.with_tenant(organisation) do
            config_b = DashboardConfiguration.find_by(user: nil, project: project_b)
            expect(config_b.layout.first['widgets'].first['key']).to eq('stats_cards')
          end
        end

        it 'removes the acting admin personal overrides across all projects' do
          ActsAsTenant.with_tenant(organisation) do
            [project_a, project_b].each do |project|
              DashboardConfiguration.create!(
                user: admin, project: project, organisation: organisation,
                layout: [{ 'widgets' => [{ 'key' => 'notifications' }] }]
              )
            end
          end

          Prosopite.pause
          begin
            patch organisation_project_dashboard_configuration_path(organisation, project_a),
                  params: layout_params.merge(save_scope: 'default_all')

            ActsAsTenant.with_tenant(organisation) do
              expect(DashboardConfiguration.where(user: admin)).to be_empty
              expect(DashboardConfiguration.where(user: nil).count).to eq(3)
            end
          ensure
            Prosopite.resume
          end
        end
      end

      # save_scope is whitelisted via presence_in(SAVE_SCOPES). An unknown/forged value (incl. one that
      # passes the start_with?('default_') admin-gate check but is not a real scope) must fall back to
      # the safest scope — a personal save for the current project only — for an ADMIN too. Tested as
      # admin so the fallback is the whitelist itself, not the role downgrade.
      it 'falls back to a personal current-project save for an unknown save_scope' do
        # The loop replays the same query shape across scopes -> Prosopite flags a false N+1.
        Prosopite.pause
        begin
          ['bogus', 'default_evil', 'personal_everything', ''].each do |bad_scope|
            # The request middleware resets the tenant after each patch, so re-scope the cleanup.
            ActsAsTenant.with_tenant(organisation) { DashboardConfiguration.delete_all }
            patch organisation_project_dashboard_configuration_path(organisation, project_a),
                  params: layout_params.merge(save_scope: bad_scope)

            ActsAsTenant.with_tenant(organisation) do
              expect(DashboardConfiguration.where(user: nil)).to be_empty, "#{bad_scope.inspect} must not write a project default"
              expect(DashboardConfiguration.find_by(user: admin, project: project_a)).to be_present
              expect(DashboardConfiguration.find_by(user: admin, project: project_b)).to be_nil
            end
          end
        ensure
          Prosopite.resume
        end
      end

      it 'falls back to a personal current-project save when save_scope is omitted entirely' do
        patch organisation_project_dashboard_configuration_path(organisation, project_a), params: layout_params

        ActsAsTenant.with_tenant(organisation) do
          expect(DashboardConfiguration.where(user: nil)).to be_empty
          expect(DashboardConfiguration.find_by(user: admin, project: project_a)).to be_present
          expect(DashboardConfiguration.find_by(user: admin, project: project_b)).to be_nil
        end
      end
    end

    context 'as non-admin member' do
      before { sign_in member }

      it 'downgrades default_this to a personal save (no shared default created)' do
        patch organisation_project_dashboard_configuration_path(organisation, project_a),
              params: layout_params.merge(save_scope: 'default_this')

        ActsAsTenant.with_tenant(organisation) do
          expect(DashboardConfiguration.find_by(user: nil, project: project_a)).to be_nil
          expect(DashboardConfiguration.find_by(user: member, project: project_a)).to be_present
        end
      end

      it 'downgrades default_all to a personal save for the current project only' do
        patch organisation_project_dashboard_configuration_path(organisation, project_a),
              params: layout_params.merge(save_scope: 'default_all')

        ActsAsTenant.with_tenant(organisation) do
          expect(DashboardConfiguration.where(user: nil)).to be_empty
          expect(DashboardConfiguration.find_by(user: member, project: project_a)).to be_present
          expect(DashboardConfiguration.find_by(user: member, project: project_b)).to be_nil
        end
      end

      it 'applies personal_all only to projects the member can access' do
        patch organisation_project_dashboard_configuration_path(organisation, project_a),
              params: layout_params.merge(save_scope: 'personal_all')

        ActsAsTenant.with_tenant(organisation) do
          expect(DashboardConfiguration.find_by(user: member, project: project_a)).to be_present
          # Member is scoped to project_a only -> b/c stay untouched
          expect(DashboardConfiguration.find_by(user: member, project: project_b)).to be_nil
          expect(DashboardConfiguration.find_by(user: member, project: project_c)).to be_nil
          expect(DashboardConfiguration.where(user: nil)).to be_empty
        end
      end
    end

    context 'authentication' do
      it 'redirects unauthenticated users' do
        patch organisation_project_dashboard_configuration_path(organisation, project_a), params: layout_params
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # Width (units) persistence: a per-widget `units` above the minimum is stored across the save
  # paths; an over-full row (Σ units > ROW_UNITS) is rejected at the model with a frame 422.
  describe 'PATCH #update with widget units' do
    before { sign_in admin }

    it 'persists per-widget units on the user-config path' do
      params = { rows: { '0' => { widgets: { '0' => { key: 'recent_tickets', units: '4' } } } } }

      patch organisation_project_dashboard_configuration_path(organisation, project_a), params: params
      expect(response).to redirect_to(organisation_project_path(organisation, project_a))

      ActsAsTenant.with_tenant(organisation) do
        widget = DashboardConfiguration.find_by(user: admin, project: project_a).layout.first['widgets'].first
        expect(widget['units']).to eq(4)
      end
    end

    it 'persists units on the project-default path too' do
      params = { save_scope: 'default_this',
                 rows: { '0' => { widgets: { '0' => { key: 'recent_tickets', units: '4' } } } } }

      patch organisation_project_dashboard_configuration_path(organisation, project_a), params: params

      ActsAsTenant.with_tenant(organisation) do
        widget = DashboardConfiguration.find_by(user: nil, project: project_a).layout.first['widgets'].first
        expect(widget['units']).to eq(4)
      end
    end

    it 'rejects a row whose units exceed ROW_UNITS with a frame-only 422 and persists nothing' do
      params = { rows: { '0' => { widgets: { '0' => { key: 'recent_tickets', units: '4' },
                                             '1' => { key: 'recent_notes', units: '4' } } } } } # 8 > 6

      patch organisation_project_dashboard_configuration_path(organisation, project_a), params: params

      expect(response).to have_http_status(:unprocessable_content)
      ActsAsTenant.with_tenant(organisation) do
        expect(DashboardConfiguration.find_by(user: admin, project: project_a)).to be_nil
      end
    end

    it 'leaves the bare shape untouched when no units is sent (the minimum is the default)' do
      patch organisation_project_dashboard_configuration_path(organisation, project_a), params: layout_params

      ActsAsTenant.with_tenant(organisation) do
        widget = DashboardConfiguration.find_by(user: admin, project: project_a).layout.first['widgets'].first
        expect(widget).to eq({ 'key' => 'stats_cards' })
      end
    end

    it 'persists a per-widget item limit on the user-config path' do
      params = { rows: { '0' => { type: 'full',
                                  widgets: { '0' => { key: 'recent_tickets', display: 'list', limit: '15' } } } } }

      patch organisation_project_dashboard_configuration_path(organisation, project_a), params: params
      expect(response).to redirect_to(organisation_project_path(organisation, project_a))

      ActsAsTenant.with_tenant(organisation) do
        widget = DashboardConfiguration.find_by(user: admin, project: project_a).layout.first['widgets'].first
        expect(widget['limit']).to eq(15)
      end
    end

    # Connected boundary: the editor can never POST an invalid limit because the parser sanitises it
    # against LIST_LIMIT_OPTIONS BEFORE persistence — so a forged param is silently dropped and the
    # save succeeds (no 422). The model's widget_limit_invalid is the separate defense-in-depth for a
    # directly hand-crafted JSONB (covered in the model spec), not for this path.
    it 'silently drops a forged out-of-whitelist limit param instead of 422' do
      params = { rows: { '0' => { type: 'full',
                                  widgets: { '0' => { key: 'recent_tickets', limit: '7' } } } } }

      patch organisation_project_dashboard_configuration_path(organisation, project_a), params: params
      expect(response).to redirect_to(organisation_project_path(organisation, project_a))

      ActsAsTenant.with_tenant(organisation) do
        widget = DashboardConfiguration.find_by(user: admin, project: project_a).layout.first['widgets'].first
        expect(widget).not_to have_key('limit')
      end
    end
  end

  describe 'GET #edit' do
    context 'as non-admin member' do
      before { sign_in member }

      it 'offers the personal save scopes but hides the admin default scopes' do
        get edit_organisation_project_dashboard_configuration_path(organisation, project_a)

        expect(response.body).to include('value="personal_this"')
        expect(response.body).to include('value="personal_all"')
        expect(response.body).not_to include('value="default_this"')
        expect(response.body).not_to include('value="default_all"')
      end

      # A1: the editable slot is independent of the component's render? — a widget the user cannot
      # access must NOT crash the edit view and must stay movable/removable.
      it 'renders 200 with a "no access" placeholder for an inaccessible widget' do
        # member has only tickets read_only on project_a → recent_notes (needs notes) is gated
        ActsAsTenant.with_tenant(organisation) do
          DashboardConfiguration.create!(
            user: member, project: project_a, organisation: organisation,
            layout: [{ 'widgets' => [{ 'key' => 'recent_tickets' }, { 'key' => 'recent_notes' }] }]
          )
        end

        get edit_organisation_project_dashboard_configuration_path(organisation, project_a)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('dashboard.configuration.no_access'))

        # "Stays movable/removable" (A1 contract): the slot chrome + the serialization input are gated
        # on widget_key.present?, NOT on no_access — only the preview swaps to a placeholder. Assert the
        # no-access slot keeps its ⋯ menu AND its [key] input (so it serializes and survives a save).
        doc = Nokogiri::HTML(response.body)
        slot = doc.at_css("[data-slot][data-widget-key='recent_notes']")
        expect(slot).to be_present
        expect(slot.at_css('[data-slot-menu-button]')).to be_present
        expect(slot.at_css("input[name='rows[0][widgets][1][key]'][value='recent_notes']")).to be_present
      end

      it 'renders an add-widget affordance' do
        ActsAsTenant.with_tenant(organisation) do
          DashboardConfiguration.create!(
            user: member, project: project_a, organisation: organisation,
            layout: [{ 'widgets' => [{ 'key' => 'recent_tickets' }] }]
          )
        end

        get edit_organisation_project_dashboard_configuration_path(organisation, project_a)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('dashboard.configuration.add_widget'))
      end
    end

    context 'as admin' do
      before { sign_in admin }

      it 'offers all four save scopes' do
        get edit_organisation_project_dashboard_configuration_path(organisation, project_a)

        expect(response.body).to include('value="personal_this"')
        expect(response.body).to include('value="personal_all"')
        expect(response.body).to include('value="default_this"')
        expect(response.body).to include('value="default_all"')
      end
    end
  end

  # A2: a validation failure must re-render the #dashboard frame ONLY (HTTP 422, layout: false)
  # carrying the in-progress (rejected) layout — not navigate away, not strip the work, not emit app
  # chrome. Pinned for every save path including the save_to_all_projects rescue (which must render
  # explicitly, not re-raise — turbo#1005).
  describe 'PATCH #update validation failure (frame-only 422)' do
    # An over-full row (recent_tickets 4 + recent_notes 4 = 8 > 6) → row_units_exceeds; both widgets
    # still render, so the in-progress layout is observable in the body.
    let(:invalid_layout) do
      { rows: { '0' => { widgets: { '0' => { key: 'recent_tickets', units: '4' },
                                    '1' => { key: 'recent_notes', units: '4' } } } } }
    end

    shared_examples 'a frame-only 422' do
      it 'returns 422 with the dashboard frame, the rejected layout, and no app chrome' do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('<turbo-frame id="dashboard"')
        expect(response.body).to include('data-widget-key="recent_tickets"')
        expect(response.body).to include('data-widget-key="recent_notes"')
        expect(response.body).not_to include('<html')
      end

      it 'surfaces the validation error message in the frame' do
        # Pins the error callout for EVERY save path — including the apply-to-all rescue, which must
        # re-validate (config.valid?) to populate errors[:layout]. Without this, deleting the callout
        # (or the rescue's re-validation) leaves the user a blank 422 and the other assertions stay green.
        expected = ERB::Util.html_escape(
          I18n.t('activerecord.errors.models.dashboard_configuration.attributes.layout.row_units_exceeds',
                 row: 1, max: Dashboards::LayoutEngine::ROW_UNITS)
        )
        expect(response.body).to include(expected)
      end
    end

    context 'user-config path (member)' do
      before do
        sign_in member
        patch organisation_project_dashboard_configuration_path(organisation, project_a), params: invalid_layout
      end

      it_behaves_like 'a frame-only 422'

      it 'does not persist the invalid layout' do
        ActsAsTenant.with_tenant(organisation) do
          expect(DashboardConfiguration.find_by(user: member, project: project_a)).to be_nil
        end
      end
    end

    context 'project-default path (admin)' do
      before do
        sign_in admin
        patch organisation_project_dashboard_configuration_path(organisation, project_a),
              params: invalid_layout.merge(save_scope: 'default_this')
      end

      it_behaves_like 'a frame-only 422'

      it 'does not persist a project default' do
        ActsAsTenant.with_tenant(organisation) do
          expect(DashboardConfiguration.find_by(user: nil, project: project_a)).to be_nil
        end
      end
    end

    context 'apply-to-all path (admin, rescue RecordInvalid)' do
      before do
        sign_in admin
        patch organisation_project_dashboard_configuration_path(organisation, project_a),
              params: invalid_layout.merge(save_scope: 'default_all')
      end

      it_behaves_like 'a frame-only 422'

      it 'rolls back: no project default is created for any project' do
        ActsAsTenant.with_tenant(organisation) do
          expect(DashboardConfiguration.where(user: nil)).to be_empty
        end
      end
    end
  end

  # Guard: an empty layout (zero rows) would silently inherit the SYSTEM default on the next view
  # (resolve_layout treats [] as "no preference") while reporting "saved". The editor blocks this
  # client-side; the server backstops it as a frame-only 422 so a forged/empty POST can't slip through.
  describe 'PATCH #update with an empty layout (guard)' do
    before { sign_in member }

    it 'refuses an empty layout with a frame-only 422 and persists nothing' do
      patch organisation_project_dashboard_configuration_path(organisation, project_a), params: {}

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('<turbo-frame id="dashboard"')
      expect(response.body).not_to include('<html')
      expect(response.body).to include(
        ERB::Util.html_escape(
          I18n.t('activerecord.errors.models.dashboard_configuration.attributes.layout.empty_not_allowed')
        )
      )

      ActsAsTenant.with_tenant(organisation) do
        expect(DashboardConfiguration.find_by(user: member, project: project_a)).to be_nil
      end
    end
  end

  # The live-preview endpoint (POST widget_preview) re-renders ONE widget with its unsaved settings
  # so flipping a card back shows the change at once. It must return a layout-free fragment and pick
  # the right branch: live component / no-access placeholder / neutral label placeholder.
  describe 'POST #widget_preview' do
    before { sign_in member } # member: tickets read_only on project_a, NO notes access

    it 'renders the live component for an accessible widget, layout-free' do
      post widget_preview_organisation_project_dashboard_configuration_path(organisation, project_a),
           params: { widget: { key: 'recent_tickets', display: 'list', period: 'this_week' } }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('pointer-events-none') # the live-component branch of _widget_preview
      expect(response.body).not_to include('<html') # fragment only, no app chrome
    end

    it 'renders the no-access placeholder for a widget the viewer cannot see' do
      post widget_preview_organisation_project_dashboard_configuration_path(organisation, project_a),
           params: { widget: { key: 'recent_notes' } } # member lacks notes access

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('dashboard.configuration.no_access'))
    end

    it 'renders the neutral label placeholder for a blank widget (no component)' do
      post widget_preview_organisation_project_dashboard_configuration_path(organisation, project_a),
           params: { widget: { key: '' } }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('dashboard-edit-placeholder')
      expect(response.body).not_to include('pointer-events-none')
    end
  end

  # Every action authorizes @project, :show?. A viewer without read access to the project must be
  # turned away (Pundit -> redirect), never served the editor or allowed to write. member has a
  # permission on project_a but NONE on project_b.
  describe 'authorization (no project access)' do
    before { sign_in member }

    it 'redirects GET #edit away from a project the user cannot see' do
      get edit_organisation_project_dashboard_configuration_path(organisation, project_b)
      expect(response).to have_http_status(:redirect)
    end

    it 'refuses PATCH #update and persists nothing for an inaccessible project' do
      patch organisation_project_dashboard_configuration_path(organisation, project_b), params: layout_params
      expect(response).to have_http_status(:redirect)
      ActsAsTenant.with_tenant(organisation) do
        expect(DashboardConfiguration.find_by(user: member, project: project_b)).to be_nil
      end
    end

    it 'refuses POST #widget_preview for an inaccessible project' do
      post widget_preview_organisation_project_dashboard_configuration_path(organisation, project_b),
           params: { widget: { key: 'recent_tickets' } }
      expect(response).to have_http_status(:redirect)
    end
  end

  # Reset deletes the user's OWN config so the dashboard falls back to the project/system default.
  describe 'DELETE #reset' do
    before { sign_in member }

    it "destroys the user's config and redirects to the dashboard" do
      ActsAsTenant.with_tenant(organisation) do
        DashboardConfiguration.create!(user: member, project: project_a, organisation: organisation,
                                       layout: [{ 'widgets' => [{ 'key' => 'recent_tickets' }] }])
      end

      delete reset_organisation_project_dashboard_configuration_path(organisation, project_a)

      expect(response).to redirect_to(organisation_project_path(organisation, project_a))
      ActsAsTenant.with_tenant(organisation) do
        expect(DashboardConfiguration.find_by(user: member, project: project_a)).to be_nil
      end
    end
  end
end
