# frozen_string_literal: true

require 'rails_helper'

# Visibility guard for the time-session list (found in the third-party review of
# PR #592): the index base query bypassed TimeSessionPolicy::Scope, so a user
# with only can_view_own saw ALL sessions of ALL users, org-wide even across
# projects, including descriptions and sums. Every list read path (project
# list, org-wide list, smart-folder branch, sum, create-stream re-render) must
# run through the policy scope.
RSpec.describe 'Organisations::TimeSessions visibility', type: :request do
  let(:organisation) { create(:organisation) }
  let(:member_role) { create(:role, organisation: organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  let(:viewer) { create(:user) }
  let(:colleague) { create(:user) }

  let(:project_a) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end
  let(:project_b) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let!(:viewer_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: viewer, organisation: organisation, role: member_role, active: true)
    end
  end

  # Durations are distinct per row for readability. Note: distinct values HIDE a
  # SUM(DISTINCT)-collapse rather than exposing it (equal values would catch it);
  # the sums in this file pin the SCOPING, not DISTINCT behaviour.
  let!(:own_session_one) do
    create_time_entry(project: project_a, creator: viewer, duration: 30, description: 'Eigene Zeile Alpha')
  end
  let!(:own_session_two) do
    create_time_entry(project: project_a, creator: viewer, duration: 45, description: 'Eigene Zeile Beta')
  end
  let!(:foreign_session_a) do
    create_time_entry(project: project_a, creator: colleague, duration: 60, description: 'Fremde Zeile Gamma')
  end
  let!(:foreign_session_b) do
    create_time_entry(project: project_b, creator: colleague, duration: 90, description: 'Fremde Zeile Delta')
  end

  let(:all_status_filters) { TimeSession::BILLING_STATUS_FILTERS }

  before do
    ActsAsTenant.current_tenant = organisation
    # Skip N+1 detection WITHOUT leaking the scan (pattern from
    # time_sessions_index_table_spec.rb).
    Prosopite.pause
  end

  after { Prosopite.resume }

  def create_time_entry(project:, creator:, duration:, description:)
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session, organisation: organisation, project: project,
                            creator: creator, duration: duration, description: description)
    end
  end

  def grant_permission(user, project, **flags)
    ActsAsTenant.with_tenant(organisation) do
      create(:time_session_permission, user: user, project: project, **flags)
    end
  end

  context 'als Nutzer mit can_view_own in Projekt A' do
    before do
      grant_permission(viewer, project_a, can_view_own: true, can_view_all: false)
      sign_in viewer
    end

    it 'zeigt mit Projektfilter nur eigene Zeilen' do
      get organisation_time_sessions_path(organisation, project_id_filter: project_a.id, date_range: 'all')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Eigene Zeile Alpha')
      expect(response.body).to include('Eigene Zeile Beta')
      expect(response.body).not_to include('Fremde Zeile Gamma')
    end

    it 'zeigt in der org-weiten Liste nur eigene Zeilen, auch nicht aus fremden Projekten' do
      get organisation_time_sessions_path(organisation, date_range: 'all')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Eigene Zeile Alpha')
      expect(response.body).not_to include('Fremde Zeile Gamma')
      expect(response.body).not_to include('Fremde Zeile Delta')
    end

    it 'summiert nur die eigenen Minuten' do
      get organisation_time_sessions_path(organisation),
          params: { date_range: 'all', status_filters: all_status_filters }

      expect(response).to have_http_status(:ok)
      expect(assigns(:total_filtered_duration)).to eq(75)
    end

    # Value of this example is ONLY the :ok crash guard for Scope#resolve's
    # scope.first probing on an empty relation. A foreign-row assertion here
    # would be vacuum-green: project scoping excludes those rows before the fix.
    it 'antwortet 200 fuer ein Projekt ohne Sessions (Scope-Probing auf leerer Relation crasht nicht)' do
      empty_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      grant_permission(viewer, empty_project, can_view_own: true, can_view_all: false)

      get organisation_time_sessions_path(organisation, project_id_filter: empty_project.id, date_range: 'all')

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Fremde Zeile Gamma')
    end

    # The THIRD fix path (load_time_sessions_for_index): the list frame re-render
    # after a create with context=index_page. Every other example here GETs; the
    # existing create-specs run as admin, so without this example the
    # policy_scope line in load_time_sessions_for_index could be deleted and the
    # whole suite stayed green (mutation-probed before adding it).
    it 'verengt auch das Listen-Re-Render nach dem Anlegen (context=index_page)' do
      post organisation_time_sessions_path(organisation),
           params: { context: 'index_page',
                     time_session: { duration_string: '0:15', occurred_on: Date.current.to_s,
                                     description: 'Eigene neue Zeile', project_id: project_a.id } },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Eigene Zeile Alpha')
      expect(response.body).not_to include('Fremde Zeile Gamma')
    end

    # End-to-end through the REAL SmartFolderService (no stub): before the
    # builder fix a time smart folder answered NONE for every non-admin, so the
    # own row was invisible — the stubbed example below cannot see that.
    it 'zeigt im echten Smart-Folder-Pfad die eigenen Zeilen (und keine fremden)' do
      smart_folder = ActsAsTenant.with_tenant(organisation) do
        folder = create(:smart_folder, organisation: organisation, user: viewer,
                                       project: nil, target_object_type: 'TimeSession')
        group = create(:smart_folder_rule_group, smart_folder: folder, position: 1)
        create(:smart_folder_rule, smart_folder_rule_group: group, position: 1,
                                   field: 'created_at', operator: 'in_the_last_days', value: '30')
        folder
      end

      get organisation_time_sessions_path(organisation, date_range: 'all',
                                                        smart_folder_id: smart_folder.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Eigene Zeile Alpha')
      expect(response.body).not_to include('Fremde Zeile Gamma')
    end

    it 'verengt auch den Smart-Folder-Zweig auf eigene Zeilen' do
      smart_folder = ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder, organisation: organisation, user: viewer,
                              project: nil, target_object_type: 'TimeSession')
      end
      # Array, not a Relation: SmartFolderService#fetch_results returns items as
      # an ARRAY in production (combine_and_sort_results builds [] + concat), so
      # the Relation branch in the index is dead code. Stubbing an Array makes
      # this guard prove the real ID-list fallback path.
      folder_items = TimeSession.where(id: [own_session_one.id, foreign_session_a.id]).to_a
      allow_any_instance_of(SmartFolderService).to receive(:fetch_results)
        .and_return({ items: folder_items })

      get organisation_time_sessions_path(organisation, date_range: 'all',
                                                        smart_folder_id: smart_folder.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Eigene Zeile Alpha')
      expect(response.body).not_to include('Fremde Zeile Gamma')
    end
  end

  # The one list carries every project the reader may see, each at its own
  # tier (doc/zeiten_eine_liste_plan.md). The project select, the "only my
  # time" pill, the selected-session lookup and the menu gate follow the same
  # rule as the rows.
  context 'als Nutzer mit "nur eigene" in Projekt A und "alle" in Projekt B' do
    let(:project_c) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt C ohne Sichtflag') }
    end
    let(:project_d) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Projekt D ohne Zeile') }
    end
    let(:only_mine_label) { I18n.t('views.organisations.time_sessions.index.filter_only_mine', default: 'Nur meine Zeiten') }

    before do
      grant_permission(viewer, project_a, can_view_own: true, can_view_all: false)
      grant_permission(viewer, project_b, can_view_own: true, can_view_all: true)
      grant_permission(viewer, project_c, can_view_own: false, can_view_all: false)
      project_d
      sign_in viewer
    end

    # The projects the filter OFFERS. A select's options until S7, a pill menu's
    # links since; the rule under test is unchanged -- only projects where this
    # reader may see time are offered. The blank option ("Alle Projekte") is a
    # removal link, not a project, so it carries an empty value and drops out.
    def project_select_values
      Nokogiri::HTML(response.body)
              .css('[data-filter-pill="project"] a[data-filter-pill-option]')
              .map { |node| node['data-filter-pill-option'] }
              .reject(&:blank?)
    end

    it 'zeigt org-weit eigene Zeilen aus A und alle aus B' do
      get organisation_time_sessions_path(organisation, date_range: 'all')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Eigene Zeile Alpha')
      expect(response.body).to include('Fremde Zeile Delta')
      expect(response.body).not_to include('Fremde Zeile Gamma')
    end

    it 'zeigt mit Projektfilter A nur eigene Zeilen aus A' do
      get organisation_time_sessions_path(organisation, date_range: 'all', project_id_filter: project_a.id)

      expect(response.body).to include('Eigene Zeile Alpha')
      expect(response.body).not_to include('Fremde Zeile Gamma')
      expect(response.body).not_to include('Fremde Zeile Delta')
    end

    it 'bietet im Projekt-Auswahlfeld nur Projekte an, in denen der Nutzer Zeit sieht' do
      get organisation_time_sessions_path(organisation)

      values = project_select_values
      expect(values).to include(project_a.id, project_b.id)
      expect(values).not_to include(project_c.id)
      expect(values).not_to include(project_d.id)
    end

    it 'zeigt die Pille "Nur meine Zeiten" nur, wo sie etwas aendern kann' do
      get organisation_time_sessions_path(organisation, project_id_filter: project_a.id)
      expect(response.body).not_to include(only_mine_label)

      get organisation_time_sessions_path(organisation, project_id_filter: project_b.id)
      expect(response.body).to include(only_mine_label)

      get organisation_time_sessions_path(organisation)
      expect(response.body).to include(only_mine_label)
    end

    it 'sperrt die Seite hinter einer deaktivierten Mitgliedschaft' do
      viewer_membership.update!(active: false)

      get organisation_time_sessions_path(organisation)

      expect(response).to have_http_status(:found)
    end
  end

  # TimeSessionPolicy#index? (the class case) is the door to the list AND, via
  # global_search_available?, to the global search; the org navigation block
  # asks it too. A row that grants no viewing flag used to pass (mere
  # existence). Pinned here at the two request-level gates so the reach of the
  # tightening is on record (review of PR #675, finding 4).
  context 'als Nutzer mit einer Rechtezeile ohne Sichtflag' do
    before do
      grant_permission(viewer, project_a, can_view_own: false, can_view_all: false, can_create_own: true)
      sign_in viewer
    end

    it 'kommt nicht auf die Liste' do
      get organisation_time_sessions_path(organisation)

      expect(response).to have_http_status(:found)
    end

    it 'bekommt auch die globale Suche nicht (derselbe Riegel, search_pins#update)' do
      patch organisation_search_pin_path(organisation_id: organisation.id),
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:forbidden)
    end

    it 'bekommt beides mit einem Sichtflag (die Zeile allein war nie der Grund)' do
      viewer.time_session_permissions.find_by(project: project_a).update!(can_view_own: true)

      get organisation_time_sessions_path(organisation)
      expect(response).to have_http_status(:ok)

      patch organisation_search_pin_path(organisation_id: organisation.id),
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      expect(response).to have_http_status(:ok)
    end
  end

  context 'als Nutzer mit can_view_all in Projekt A' do
    before do
      grant_permission(viewer, project_a, can_view_own: true, can_view_all: true)
      sign_in viewer
    end

    it 'zeigt eigene und fremde Zeilen des Projekts, aber keine aus Projekten ohne Berechtigung' do
      get organisation_time_sessions_path(organisation, date_range: 'all')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Eigene Zeile Alpha')
      expect(response.body).to include('Fremde Zeile Gamma')
      expect(response.body).not_to include('Fremde Zeile Delta')
    end
  end

  context 'als Account-Admin' do
    let(:admin) { create(:user) }

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
      end
      sign_in admin
    end

    it 'zeigt alle Zeilen aller Projekte' do
      get organisation_time_sessions_path(organisation, date_range: 'all')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Eigene Zeile Alpha')
      expect(response.body).to include('Fremde Zeile Gamma')
      expect(response.body).to include('Fremde Zeile Delta')
    end
  end
end
