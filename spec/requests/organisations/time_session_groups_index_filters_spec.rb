# frozen_string_literal: true

require 'rails_helper'

# P1 of the billings redesign (doc/abrechnungen_filterzeile_und_tabelle_plan.md):
# the index filters become real. Until now only billing_status was applied; the
# project, date and search fields rendered but the controller never read them.
#
# Pinned here:
# * the status default is 'all' (decision: the list opens unfiltered, like the mockup),
#   and unknown values normalize to 'all' instead of travelling on
# * the period filters the billing's own created_at (decision D-B), presets via
#   TimeSessions::ListPeriod (table vocabulary, default 'all'), hand-typed bounds
#   win and are hardened by TimeSessions::DateBound (junk = no bound, never a 500)
# * search covers name, description and invoice number
# * the list paginates via the shared Pageable chain (user preference, default 20)
# * per-row aggregates (session count, minutes) come as grouped hashes, policy-scoped
# * nothing from another tenant ever appears, in rows or in aggregates
RSpec.describe 'Organisations::TimeSessionGroups index filters', type: :request do
  let(:organisation) { create(:organisation) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    sign_in user
    ActsAsTenant.current_tenant = organisation
    Current.user = user
  end

  after { Current.reset }

  def create_group(project: nil, sessions: 0, minutes: 60, **attrs)
    ActsAsTenant.with_tenant(organisation) do
      group = create(:time_session_group, organisation: organisation, creator: user, **attrs)
      sessions.times do
        create(:time_session, time_session_group: group, project: project,
                              organisation: organisation, creator: user, duration: minutes)
      end
      group
    end
  end

  describe 'Status' do
    let!(:open_group) { create_group }
    let!(:billed_group) { create_group(billed: true, invoice_number: 'RE-2026-118') }

    it 'zeigt ohne Parameter ALLE Abrechnungen (Default all, nicht mehr unbilled)' do
      get organisation_time_session_groups_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(assigns(:time_session_groups)).to contain_exactly(open_group, billed_group)
      expect(assigns(:current_billing_status)).to eq('all')
    end

    it 'filtert offene Abrechnungen' do
      get organisation_time_session_groups_path(organisation, billing_status: 'unbilled')

      expect(assigns(:time_session_groups)).to contain_exactly(open_group)
    end

    it 'filtert abgerechnete Abrechnungen' do
      get organisation_time_session_groups_path(organisation, billing_status: 'billed')

      expect(assigns(:time_session_groups)).to contain_exactly(billed_group)
    end

    it 'versteht das Set billing_states[] als Besitzer des Filters' do
      get organisation_time_session_groups_path(organisation, billing_states: ['billed'])

      expect(assigns(:time_session_groups)).to contain_exactly(billed_group)
      expect(assigns(:effective_billing_states)).to eq(['billed'])
    end

    it 'normalisiert einen unbekannten Status auf all statt ihn weiterreisen zu lassen' do
      get organisation_time_session_groups_path(organisation, billing_status: 'evil')

      expect(response).to have_http_status(:ok)
      expect(assigns(:time_session_groups)).to contain_exactly(open_group, billed_group)
      expect(assigns(:current_billing_status)).to eq('all')
    end
  end

  describe 'Projekt' do
    let!(:group_in_a) { create_group(project: project_a, sessions: 1) }
    let!(:group_in_b) { create_group(project: project_b, sessions: 1) }
    let!(:group_without_sessions) { create_group }

    it 'filtert nach dem Projekt der enthaltenen Zeiten' do
      get organisation_time_session_groups_path(organisation, project_id: project_a.id)

      expect(assigns(:time_session_groups)).to contain_exactly(group_in_a)
    end

    it 'ignoriert einen leeren project_id' do
      get organisation_time_session_groups_path(organisation, project_id: '')

      expect(assigns(:time_session_groups))
        .to contain_exactly(group_in_a, group_in_b, group_without_sessions)
    end
  end

  describe 'Zeitwahl (created_at der Abrechnung, D-B)' do
    let!(:group_last_year) do
      create_group(created_at: Time.zone.local(Date.current.year - 1, 2, 10, 12))
    end
    let!(:group_mid) { create_group(created_at: Time.zone.local(2025, 6, 15, 12)) }
    let!(:group_now) { create_group }

    it 'hat ohne Parameter den Zeitraum all (Default der Tabelle, nicht der Liste)' do
      get organisation_time_session_groups_path(organisation)

      expect(assigns(:effective_date_range)).to eq('all')
      expect(assigns(:time_session_groups))
        .to contain_exactly(group_last_year, group_mid, group_now)
    end

    it 'wendet einen Preset auf das created_at der Abrechnung an' do
      get organisation_time_session_groups_path(organisation, date_range: 'year')

      expect(assigns(:time_session_groups)).to contain_exactly(group_now)
    end

    it 'normalisiert einen unbekannten Zeitraum auf all' do
      get organisation_time_session_groups_path(organisation, date_range: 'evil')

      expect(response).to have_http_status(:ok)
      expect(assigns(:effective_date_range)).to eq('all')
      expect(assigns(:time_session_groups))
        .to contain_exactly(group_last_year, group_mid, group_now)
    end

    it 'filtert nach eigenen Grenzen, ganze Tage einschliesslich' do
      get organisation_time_session_groups_path(organisation,
                                                start_date: '2025-06-15', end_date: '2025-06-15')

      expect(assigns(:time_session_groups)).to contain_exactly(group_mid)
    end

    it 'getippte Grenzen schlagen den Preset' do
      get organisation_time_session_groups_path(organisation,
                                                date_range: 'year',
                                                start_date: '2025-06-01', end_date: '2025-06-30')

      expect(assigns(:effective_date_range)).to eq(TimeSessions::ListPeriod::CUSTOM)
      expect(assigns(:time_session_groups)).to contain_exactly(group_mid)
    end

    it 'behandelt Muell-Daten als keine Grenze statt mit 500 zu antworten' do
      get organisation_time_session_groups_path(organisation,
                                                start_date: '99999-01-01', end_date: 'not-a-date')

      expect(response).to have_http_status(:ok)
      expect(assigns(:time_session_groups))
        .to contain_exactly(group_last_year, group_mid, group_now)
    end
  end

  describe 'Suche' do
    let!(:named_group) { create_group(name: '08-2026-pselector') }
    let!(:described_group) { create_group(name: 'Zweite', description: 'Portal Relaunch Arbeiten') }
    let!(:invoiced_group) { create_group(name: 'Dritte', billed: true, invoice_number: 'RE-2026-118') }

    it 'sucht im Namen, case-insensitive' do
      get organisation_time_session_groups_path(organisation, search: 'PSELECTOR')

      expect(assigns(:time_session_groups)).to contain_exactly(named_group)
    end

    it 'sucht in der Beschreibung' do
      get organisation_time_session_groups_path(organisation, search: 'Relaunch')

      expect(assigns(:time_session_groups)).to contain_exactly(described_group)
    end

    it 'sucht in der Rechnungsnummer' do
      get organisation_time_session_groups_path(organisation, search: 'RE-2026')

      expect(assigns(:time_session_groups)).to contain_exactly(invoiced_group)
    end
  end

  describe 'Kombination' do
    it 'wendet Status und Projekt zusammen an' do
      matching = create_group(project: project_a, sessions: 1)
      create_group(project: project_a, sessions: 1, billed: true, invoice_number: 'RE-1')
      create_group(project: project_b, sessions: 1)

      get organisation_time_session_groups_path(organisation,
                                                billing_status: 'unbilled', project_id: project_a.id)

      expect(assigns(:time_session_groups)).to contain_exactly(matching)
    end
  end

  describe 'Pagination' do
    it 'blaettert nach 20 Abrechnungen um (Default der Pageable-Kette)' do
      21.times { create_group }

      get organisation_time_session_groups_path(organisation)
      expect(assigns(:time_session_groups).size).to eq(20)
      expect(assigns(:pagy).pages).to eq(2)

      get organisation_time_session_groups_path(organisation, page: 2)
      expect(assigns(:time_session_groups).size).to eq(1)
    end
  end

  describe 'Summen je Zeile' do
    it 'liefert Anzahl und Minuten je Abrechnung als gebuendelte Hashes' do
      group = create_group(project: project_a, sessions: 2, minutes: 90)
      empty_group = create_group

      get organisation_time_session_groups_path(organisation)

      expect(assigns(:group_session_counts)[group.id]).to eq(2)
      expect(assigns(:group_session_minutes)[group.id]).to eq(180)
      expect(assigns(:group_session_counts)[empty_group.id]).to be_nil
      expect(response.body).to include('03:00')
    end
  end

  describe 'Mandanten-Isolation' do
    let(:other_organisation) { create(:organisation) }
    let(:other_user) { create(:user) }
    let!(:other_group) do
      ActsAsTenant.with_tenant(other_organisation) do
        group = create(:time_session_group, organisation: other_organisation,
                                            creator: other_user, name: 'Fremde Abrechnung')
        project = create(:project, organisation: other_organisation)
        create(:time_session, time_session_group: group, project: project,
                              organisation: other_organisation, creator: other_user, duration: 60)
        group
      end
    end

    it 'zeigt weder Zeilen noch Summen einer anderen Organisation' do
      own_group = create_group(project: project_a, sessions: 1)

      get organisation_time_session_groups_path(organisation)

      expect(assigns(:time_session_groups)).to contain_exactly(own_group)
      expect(assigns(:group_session_counts)).not_to have_key(other_group.id)
      expect(assigns(:group_session_minutes)).not_to have_key(other_group.id)
      expect(response.body).not_to include('Fremde Abrechnung')
    end
  end

  describe 'Berechtigung' do
    let(:plain_role) { create(:role, organisation: organisation) }
    let(:plain_user) { create(:user) }
    let!(:plain_membership) do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: plain_user, organisation: organisation, role: plain_role, active: true)
      end
    end

    it 'weist ein Mitglied ohne Admin- oder Finance-Rolle ab' do
      sign_in plain_user
      Current.user = plain_user

      get organisation_time_session_groups_path(organisation)

      expect(response).to have_http_status(:redirect)
    end
  end
end
