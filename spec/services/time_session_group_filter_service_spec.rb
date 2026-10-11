# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TimeSessionGroupFilterService do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:project_a) { create(:project, organisation: organisation) }
  let(:project_b) { create(:project, organisation: organisation) }

  let(:base_query) { TimeSessionGroup.where(organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  # Helper: create a group with TimeSession(s) in a project
  def create_group_with_sessions(project:, occurred_on: Date.current, count: 1, **group_attrs)
    group = create(:time_session_group, organisation: organisation, creator: user, **group_attrs)
    count.times do
      create(:time_session,
             time_session_group: group,
             project: project,
             organisation: organisation,
             creator: user,
             occurred_on: occurred_on)
    end
    group
  end

  describe '#call' do
    context 'ohne Filter' do
      it 'gibt alle Gruppen der base_query zurueck' do
        group_a = create_group_with_sessions(project: project_a)
        group_b = create_group_with_sessions(project: project_b)

        result = described_class.new(base_query: base_query).call

        expect(result).to contain_exactly(group_a, group_b)
      end

      it 'gibt leeres Ergebnis bei leerer base_query zurueck' do
        create_group_with_sessions(project: project_a)
        empty_query = TimeSessionGroup.none

        result = described_class.new(base_query: empty_query).call

        expect(result).to be_empty
      end
    end

    context 'Projekt-Filter' do
      let!(:group_in_a) { create_group_with_sessions(project: project_a) }
      let!(:group_in_b) { create_group_with_sessions(project: project_b) }

      it 'filtert Gruppen nach project_id' do
        result = described_class.new(base_query: base_query, project_id: project_a.id).call

        expect(result).to contain_exactly(group_in_a)
      end

      it 'gibt Gruppe zurueck wenn sie Sessions in mehreren Projekten hat' do
        # group_in_a also gets a session in project_b
        create(:time_session,
               time_session_group: group_in_a,
               project: project_b,
               organisation: organisation,
               creator: user,
               occurred_on: Date.current)

        result = described_class.new(base_query: base_query, project_id: project_b.id).call

        expect(result).to contain_exactly(group_in_a, group_in_b)
      end

      it 'gibt keine Duplikate zurueck bei mehreren Sessions im selben Projekt' do
        create_group_with_sessions(project: project_a, count: 3)
        # group_in_a still exists as well

        result = described_class.new(base_query: base_query, project_id: project_a.id).call

        expect(result.to_a.size).to eq(result.to_a.uniq.size)
      end

      it 'ignoriert leeren project_id' do
        result = described_class.new(base_query: base_query, project_id: '').call

        expect(result).to contain_exactly(group_in_a, group_in_b)
      end

      it 'ignoriert nil project_id' do
        result = described_class.new(base_query: base_query, project_id: nil).call

        expect(result).to contain_exactly(group_in_a, group_in_b)
      end

      it 'gibt leeres Ergebnis bei nicht-existierender project_id' do
        result = described_class.new(base_query: base_query, project_id: SecureRandom.uuid).call

        expect(result).to be_empty
      end
    end

    context 'Abrechnungsstatus-Filter' do
      let!(:billed_group) { create_group_with_sessions(project: project_a, billed: true, invoice_number: 'INV-001') }
      let!(:unbilled_group) { create_group_with_sessions(project: project_a) }

      it 'filtert abgerechnete Gruppen' do
        result = described_class.new(base_query: base_query, billing_status: 'billed').call

        expect(result).to contain_exactly(billed_group)
      end

      it 'filtert nicht-abgerechnete Gruppen' do
        result = described_class.new(base_query: base_query, billing_status: 'unbilled').call

        expect(result).to contain_exactly(unbilled_group)
      end

      it 'ignoriert unbekannten billing_status' do
        result = described_class.new(base_query: base_query, billing_status: 'invalid').call

        expect(result).to contain_exactly(billed_group, unbilled_group)
      end

      it 'ignoriert leeren billing_status' do
        result = described_class.new(base_query: base_query, billing_status: '').call

        expect(result).to contain_exactly(billed_group, unbilled_group)
      end

      it 'ignoriert nil billing_status' do
        result = described_class.new(base_query: base_query, billing_status: nil).call

        expect(result).to contain_exactly(billed_group, unbilled_group)
      end
    end

    context 'Datumsbereich-Filter (created_at der Abrechnung)' do
      # P1 of the billings redesign (decision D-B in
      # doc/abrechnungen_filterzeile_und_tabelle_plan.md): the period filters the
      # billing's own created_at -- the "erstellt" column the list shows -- not
      # the member sessions' occurred_on. The occurred_on semantics never
      # shipped: the service existed but was not wired into the page.
      let!(:old_group) { create_group_with_sessions(project: project_a, created_at: Time.zone.local(2025, 1, 15, 12)) }
      let!(:mid_group) { create_group_with_sessions(project: project_a, created_at: Time.zone.local(2025, 6, 15, 12)) }
      let!(:new_group) { create_group_with_sessions(project: project_a, created_at: Time.zone.local(2025, 12, 15, 12)) }

      it 'filtert nach start_date und end_date' do
        result = described_class.new(
          base_query: base_query,
          start_date: '2025-03-01',
          end_date: '2025-09-30'
        ).call

        expect(result).to contain_exactly(mid_group)
      end

      it 'schliesst Randdaten ein (inklusiver Bereich, ganze Tage)' do
        result = described_class.new(
          base_query: base_query,
          start_date: '2025-06-15',
          end_date: '2025-06-15'
        ).call

        expect(result).to contain_exactly(mid_group)
      end

      it 'filtert nur nach start_date (ab Datum)' do
        result = described_class.new(
          base_query: base_query,
          start_date: '2025-06-01'
        ).call

        expect(result).to contain_exactly(mid_group, new_group)
      end

      it 'filtert nur nach end_date (bis Datum)' do
        result = described_class.new(
          base_query: base_query,
          end_date: '2025-06-30'
        ).call

        expect(result).to contain_exactly(old_group, mid_group)
      end

      it 'filtert eine Abrechnung ohne Zeiten nach ihrem created_at (kein Join noetig)' do
        empty_group = create(:time_session_group, organisation: organisation, creator: user,
                                                  created_at: Time.zone.local(2025, 6, 20, 12))

        result = described_class.new(
          base_query: base_query,
          start_date: '2025-06-01',
          end_date: '2025-06-30'
        ).call

        expect(result).to contain_exactly(mid_group, empty_group)
      end

      it 'ignoriert ungueltiges start_date Format' do
        result = described_class.new(
          base_query: base_query,
          start_date: 'not-a-date',
          end_date: '2025-12-31'
        ).call

        expect(result).to contain_exactly(old_group, mid_group, new_group)
      end

      it 'ignoriert ungueltiges end_date Format' do
        result = described_class.new(
          base_query: base_query,
          start_date: '2025-01-01',
          end_date: 'xyz'
        ).call

        expect(result).to contain_exactly(old_group, mid_group, new_group)
      end

      it 'ignoriert beide ungueltige Datumsformate' do
        result = described_class.new(
          base_query: base_query,
          start_date: 'abc',
          end_date: 'xyz'
        ).call

        expect(result).to contain_exactly(old_group, mid_group, new_group)
      end

      it 'ignoriert leere Datumsfelder' do
        result = described_class.new(
          base_query: base_query,
          start_date: '',
          end_date: ''
        ).call

        expect(result).to contain_exactly(old_group, mid_group, new_group)
      end

      it 'loggt Warnung bei ungueltigen Datumsformaten' do
        expect(Rails.logger).to receive(:warn).with(/Invalid date format.*not-a-date/)

        described_class.new(
          base_query: base_query,
          start_date: 'not-a-date'
        ).call
      end
    end

    context 'Such-Filter' do
      let!(:alpha_group) do
        create_group_with_sessions(project: project_a, name: 'Alpha Sprint')
      end
      let!(:beta_group) do
        create_group_with_sessions(project: project_a, name: 'Beta Release', description: 'Wichtige Kundenarbeit')
      end
      let!(:billed_group) do
        create_group_with_sessions(
          project: project_a,
          name: 'Gamma',
          billed: true,
          invoice_number: 'INV-2025-ALPHA'
        )
      end

      it 'sucht im Namen (case-insensitive)' do
        result = described_class.new(base_query: base_query, search: 'alpha').call

        expect(result).to include(alpha_group)
      end

      it 'sucht in der Beschreibung' do
        result = described_class.new(base_query: base_query, search: 'Kundenarbeit').call

        expect(result).to contain_exactly(beta_group)
      end

      it 'sucht in der Rechnungsnummer' do
        result = described_class.new(base_query: base_query, search: 'INV-2025').call

        expect(result).to contain_exactly(billed_group)
      end

      it 'findet ueber mehrere Felder hinweg' do
        # "ALPHA" appears in the name of alpha_group AND in invoice_number of billed_group
        result = described_class.new(base_query: base_query, search: 'ALPHA').call

        expect(result).to contain_exactly(alpha_group, billed_group)
      end

      it 'entfernt fuehrende und nachfolgende Leerzeichen' do
        result = described_class.new(base_query: base_query, search: '  Alpha  ').call

        expect(result).to include(alpha_group)
      end

      it 'ignoriert leeren Suchbegriff' do
        result = described_class.new(base_query: base_query, search: '').call

        expect(result).to contain_exactly(alpha_group, beta_group, billed_group)
      end

      it 'ignoriert nil Suchbegriff' do
        result = described_class.new(base_query: base_query, search: nil).call

        expect(result).to contain_exactly(alpha_group, beta_group, billed_group)
      end

      it 'escaped SQL-Wildcards im Suchbegriff' do
        wildcard_group = create_group_with_sessions(project: project_a, name: '100% fertig')
        # Without escaping, this group would also match (%100%% == %100%)
        decoy_group = create_group_with_sessions(project: project_a, name: '1001 Nacht')

        result = described_class.new(base_query: base_query, search: '100%').call

        expect(result).to contain_exactly(wildcard_group)
        expect(result).not_to include(decoy_group)
      end

      it 'escaped SQL-Underscore im Suchbegriff' do
        underscore_group = create_group_with_sessions(project: project_a, name: 'test_gruppe')
        # Without escaping, _ would match every single character
        decoy_group = create_group_with_sessions(project: project_a, name: 'testXgruppe')

        result = described_class.new(base_query: base_query, search: 'test_').call

        expect(result).to contain_exactly(underscore_group)
        expect(result).not_to include(decoy_group)
      end

      it 'gibt leeres Ergebnis bei nicht-matchendem Suchbegriff' do
        result = described_class.new(base_query: base_query, search: 'zzz-nicht-vorhanden').call

        expect(result).to be_empty
      end
    end

    context 'kombinierte Filter' do
      let!(:billed_in_a) do
        create_group_with_sessions(
          project: project_a,
          name: 'Sprint 1',
          billed: true,
          invoice_number: 'INV-001',
          created_at: Time.zone.local(2025, 3, 15, 12)
        )
      end
      let!(:unbilled_in_a) do
        create_group_with_sessions(
          project: project_a,
          name: 'Sprint 2',
          created_at: Time.zone.local(2025, 6, 15, 12)
        )
      end
      let!(:unbilled_in_b) do
        create_group_with_sessions(
          project: project_b,
          name: 'Sprint 3',
          created_at: Time.zone.local(2025, 6, 15, 12)
        )
      end

      it 'kombiniert Projekt- und Abrechnungsstatus-Filter' do
        result = described_class.new(
          base_query: base_query,
          project_id: project_a.id,
          billing_status: 'unbilled'
        ).call

        expect(result).to contain_exactly(unbilled_in_a)
      end

      it 'kombiniert alle Filter' do
        result = described_class.new(
          base_query: base_query,
          project_id: project_a.id,
          billing_status: 'unbilled',
          start_date: '2025-01-01',
          end_date: '2025-12-31',
          search: 'Sprint'
        ).call

        expect(result).to contain_exactly(unbilled_in_a)
      end

      it 'gibt leeres Ergebnis wenn Filter sich gegenseitig ausschliessen' do
        result = described_class.new(
          base_query: base_query,
          project_id: project_a.id,
          billing_status: 'billed',
          start_date: '2025-06-01',
          end_date: '2025-12-31'
        ).call

        # billed_in_a was created in March, not in the June-December range
        expect(result).to be_empty
      end
    end

    context 'Edge Cases' do
      it 'behandelt Gruppen ohne TimeSession korrekt beim Projekt-Filter' do
        empty_group = create(:time_session_group, organisation: organisation, creator: user)
        _group_with_sessions = create_group_with_sessions(project: project_a)

        result = described_class.new(base_query: base_query, project_id: project_a.id).call

        expect(result).not_to include(empty_group)
      end

      it 'behandelt Gruppen ohne TimeSession korrekt beim Datums-Filter' do
        empty_group = create(:time_session_group, organisation: organisation, creator: user)
        _group_with_sessions = create_group_with_sessions(project: project_a, occurred_on: Date.new(2025, 6, 15))

        result = described_class.new(base_query: base_query, start_date: '2025-01-01', end_date: '2025-12-31').call

        expect(result).not_to include(empty_group)
      end

      it 'gibt Gruppen ohne Sessions zurueck wenn kein join-basierter Filter aktiv' do
        empty_group = create(:time_session_group, organisation: organisation, creator: user)

        result = described_class.new(base_query: base_query, billing_status: 'unbilled').call

        expect(result).to include(empty_group)
      end

      it 'behandelt nur-Whitespace Suchbegriff wie leeren String' do
        group = create_group_with_sessions(project: project_a)

        result = described_class.new(base_query: base_query, search: '   ').call

        expect(result).to include(group)
      end
    end
  end
end
