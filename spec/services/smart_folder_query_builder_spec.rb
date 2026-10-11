# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolderQueryBuilder do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:regular_role) { create(:role, organisation: organisation) }
  let(:admin_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end
  let(:regular_user) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: regular_role, active: true)
    user
  end
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }

  # Helper: create a SmartFolder with rule groups and rules
  def create_smart_folder_with_rules(user:, rules_config:, target_object_type: 'Note', project_scope: project, **folder_attrs)
    folder = create(:smart_folder,
                    user: user,
                    organisation: organisation,
                    project: project_scope,
                    target_object_type: target_object_type,
                    **folder_attrs)

    rules_config.each_with_index do |group_rules, group_idx|
      group = create(:smart_folder_rule_group, smart_folder: folder, position: group_idx + 1)
      group_rules.each_with_index do |rule_attrs, rule_idx|
        create(:smart_folder_rule, smart_folder_rule_group: group, position: rule_idx + 1, **rule_attrs)
      end
    end

    folder.reload
  end

  describe '#build_results_query' do
    context 'ohne Regelgruppen' do
      it 'gibt leeres Array zurueck' do
        folder = create(:smart_folder, user: admin_user, organisation: organisation, project: project)

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to eq([])
      end
    end

    context 'einfacher Titel-Filter (contains)' do
      let!(:matching_note) { create(:note, title: 'Wichtiges Meeting', project: project, organisation: organisation, creator: admin_user) }
      let!(:non_matching_note) { create(:note, title: 'Nebensache', project: project, organisation: organisation, creator: admin_user) }

      it 'filtert Notes nach Titel' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Wichtig' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(matching_note)
        expect(result).not_to include(non_matching_note)
      end

      # Formerly: a known bug (case-sensitive). Now fixed: TextFilter uses ILIKE.
      it 'ist case-insensitive (TextFilter Bug behoben)' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'wichtiges' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(matching_note)
      end
    end

    context 'AND-Logik innerhalb einer Regelgruppe' do
      let!(:matching_note) do
        create(:note, title: 'Wichtiges Meeting',
                      project: project, organisation: organisation, creator: admin_user,
                      created_at: 2.days.ago)
      end
      let!(:title_only_match) do
        create(:note, title: 'Wichtiger Termin',
                      project: project, organisation: organisation, creator: admin_user,
                      created_at: 30.days.ago)
      end

      it 'verknuepft mehrere Regeln in einer Gruppe mit AND' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [
              { field: 'title', operator: 'contains', value: 'Wichtig' },
              { field: 'created_at', operator: 'in_the_last_days', value: '7' }
            ]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(matching_note)
        expect(result).not_to include(title_only_match)
      end
    end

    context 'OR-Logik zwischen Regelgruppen' do
      let!(:note_a) { create(:note, title: 'Alpha Bericht', project: project, organisation: organisation, creator: admin_user) }
      let!(:note_b) { create(:note, title: 'Beta Report', project: project, organisation: organisation, creator: admin_user) }
      let!(:note_c) { create(:note, title: 'Gamma Update', project: project, organisation: organisation, creator: admin_user) }

      it 'verknuepft Regelgruppen mit OR' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Alpha' }],
            [{ field: 'title', operator: 'contains', value: 'Beta' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to contain_exactly(note_a, note_b)
        expect(result).not_to include(note_c)
      end
    end

    context 'target_object_type spezifisch' do
      let!(:note) { create(:note, title: 'Test Notiz', project: project, organisation: organisation, creator: admin_user) }
      let!(:ticket) { create(:ticket, title: 'Test Ticket', project: project, organisation: organisation, creator: admin_user) }

      it 'filtert nur Notes wenn target_object_type Note ist' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          target_object_type: 'Note',
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Test' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(note)
        expect(result).not_to include(ticket)
      end

      it 'filtert nur Tickets wenn target_object_type Ticket ist' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          target_object_type: 'Ticket',
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Test' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(ticket)
        expect(result).not_to include(note)
      end
    end

    context 'target_object_type All (alle Modelle)' do
      let!(:note) { create(:note, title: 'Suchwort Notiz', project: project, organisation: organisation, creator: admin_user) }
      let!(:ticket) { create(:ticket, title: 'Suchwort Ticket', project: project, organisation: organisation, creator: admin_user) }

      it 'durchsucht alle unterstuetzten Modelle wenn target_object_type All' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          target_object_type: 'All',
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Suchwort' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(note, ticket)
      end
    end

    context 'Sortierung' do
      let!(:old_note) do
        create(:note, title: 'Alte Notiz', project: project, organisation: organisation,
                      creator: admin_user, updated_at: 3.days.ago)
      end
      let!(:new_note) do
        create(:note, title: 'Neue Notiz', project: project, organisation: organisation,
                      creator: admin_user, updated_at: 1.hour.ago)
      end

      it 'sortiert nach updated_at desc (Standard)' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Notiz' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result.first).to eq(new_note)
        expect(result.last).to eq(old_note)
      end

      it 'sortiert nach updated_at asc' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          sort_column: 'updated_at',
          sort_direction: 'asc',
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Notiz' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result.first).to eq(old_note)
        expect(result.last).to eq(new_note)
      end

      it 'sortiert nach Titel' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          sort_column: 'title',
          sort_direction: 'asc',
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Notiz' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result.map(&:title)).to eq(['Alte Notiz', 'Neue Notiz'])
      end
    end

    context 'Berechtigungen' do
      let!(:accessible_note) { create(:note, title: 'Zugaenglich', project: project, organisation: organisation, creator: admin_user) }

      it 'Admin sieht alle Ergebnisse' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Zugaenglich' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(accessible_note)
      end

      it 'regulaerer User ohne Projektzugriff sieht keine Ergebnisse' do
        folder = create_smart_folder_with_rules(
          user: regular_user,
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Zugaenglich' }]
          ]
        )

        # regular_user has no ProjectPermissions
        allow(AccessCheck::ProjectAccessService).to receive(:accessible_projects)
          .and_return(Project.none)

        result = described_class.new(folder, regular_user).build_results_query

        expect(result).to be_empty
      end
    end

    context 'Projekt-Scoping' do
      let(:other_project) { create(:project, organisation: organisation) }
      let!(:note_in_project) { create(:note, title: 'Im Projekt', project: project, organisation: organisation, creator: admin_user) }
      let!(:note_in_other) { create(:note, title: 'Im anderen Projekt', project: other_project, organisation: organisation, creator: admin_user) }

      it 'begrenzt Ergebnisse auf den SmartFolder-Projekt wenn gesetzt' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          project_scope: project,
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Im' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(note_in_project)
        expect(result).not_to include(note_in_other)
      end

      it 'gibt Ergebnisse aus allen Projekten wenn kein Projekt gesetzt' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          project_scope: nil,
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Im' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(note_in_project, note_in_other)
      end
    end

    context 'current_user Fallback' do
      it 'nutzt smart_folder.user wenn kein current_user uebergeben wird' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'x' }]
          ]
        )

        builder = described_class.new(folder)

        expect(builder.current_user).to eq(admin_user)
      end

      it 'nutzt explizit uebergebenen current_user' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'x' }]
          ]
        )

        builder = described_class.new(folder, regular_user)

        expect(builder.current_user).to eq(regular_user)
      end
    end

    context 'Edge Cases' do
      it 'gibt leeres Array wenn keine Regeln auf das Modell anwendbar sind' do
        # TimeSession has no 'title' filter
        folder = create_smart_folder_with_rules(
          user: admin_user,
          target_object_type: 'TimeSession',
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'test' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to eq([])
      end

      it 'uebergeht Regelgruppen ohne anwendbare Regeln fuer das Modell' do
        note = create(:note, title: 'Relevante Notiz', project: project, organisation: organisation, creator: admin_user)

        folder = create_smart_folder_with_rules(
          user: admin_user,
          target_object_type: 'Note',
          rules_config: [
            # Group 1: duration is only applicable to TimeSession -> is skipped
            [{ field: 'duration', operator: 'greater_than', value: '30' }],
            # Group 2: title is applicable to Note -> is executed
            [{ field: 'title', operator: 'contains', value: 'Relevante' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(note)
      end

      it 'gibt leeres Array wenn alle Regeln keine Treffer liefern' do
        create(:note, title: 'Existiert', project: project, organisation: organisation, creator: admin_user)

        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [{ field: 'title', operator: 'equals', value: 'Gibt es nicht' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to eq([])
      end

      it 'faengt Fehler in einzelnen Filter-Strategien ab und ueberspringt die Gruppe' do
        create(:note, title: 'Test', project: project, organisation: organisation, creator: admin_user)

        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Test' }]
          ]
        )

        folder.smart_folder_rules.first
        filter_double = instance_double(SmartFolders::Filters::TextFilter)
        allow(filter_double).to receive(:apply).and_raise(StandardError, 'Filter kaputt')
        allow(SmartFolders::Filters::TextFilter).to receive(:new).and_return(filter_double)

        expect(Rails.logger).to receive(:error).with(/Filter kaputt/)

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to eq([])
      end

      it 'defines safety limits as constants' do
        expect(SmartFolderQueryBuilder::IDS_PER_GROUP_LIMIT).to eq(10_000)
        expect(SmartFolderQueryBuilder::RESULTS_PER_MODEL_LIMIT).to eq(1_000)
      end

      it 'behandelt leere Regelgruppen (Gruppe ohne Regeln)' do
        folder = create(:smart_folder, user: admin_user, organisation: organisation, project: project, target_object_type: 'Note')
        create(:smart_folder_rule_group, smart_folder: folder, position: 1)
        # No rules in the group

        result = described_class.new(folder.reload, admin_user).build_results_query

        expect(result).to eq([])
      end

      it 'behandelt target_object_type mit ungueltigem Modellnamen' do
        folder = build(:smart_folder,
                       user: admin_user,
                       organisation: organisation,
                       project: project,
                       target_object_type: 'InvalidModel')
        folder.save(validate: false) # bypass validation

        group = create(:smart_folder_rule_group, smart_folder: folder)
        create(:smart_folder_rule, smart_folder_rule_group: group, field: 'title', operator: 'contains', value: 'x')

        result = described_class.new(folder.reload, admin_user).build_results_query

        expect(result).to eq([])
      end
    end

    context 'Ticket-spezifische Filter' do
      let!(:ticket_high) { create(:ticket, title: 'Dringend Bug', project: project, organisation: organisation, creator: admin_user) }
      let!(:ticket_low) { create(:ticket, title: 'Feature Request', project: project, organisation: organisation, creator: admin_user) }

      it 'filtert Tickets nach Titel' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          target_object_type: 'Ticket',
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Bug' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to contain_exactly(ticket_high)
      end
    end

    context 'Datums-Filter' do
      let!(:recent_note) { create(:note, title: 'Heute', project: project, organisation: organisation, creator: admin_user, created_at: 1.day.ago) }
      let!(:old_note) { create(:note, title: 'Frueher', project: project, organisation: organisation, creator: admin_user, created_at: 60.days.ago) }

      it 'filtert nach created_at in_the_last_days' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [{ field: 'created_at', operator: 'in_the_last_days', value: '7' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(recent_note)
        expect(result).not_to include(old_note)
      end

      it 'filtert nach created_at before' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [{ field: 'created_at', operator: 'before', value: 30.days.ago.to_date.to_s }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(old_note)
        expect(result).not_to include(recent_note)
      end
    end

    context 'Multi-Tenant Isolation' do
      let(:other_org) { create(:organisation) }
      let!(:own_note) { create(:note, title: 'Eigene Org', project: project, organisation: organisation, creator: admin_user) }

      it 'zeigt keine Objekte aus anderen Organisationen' do
        other_project = nil
        other_note = nil
        ActsAsTenant.with_tenant(other_org) do
          other_project = create(:project, organisation: other_org)
          other_note = create(:note, title: 'Eigene Org', project: other_project, organisation: other_org, creator: admin_user)
        end

        folder = create_smart_folder_with_rules(
          user: admin_user,
          rules_config: [
            [{ field: 'title', operator: 'contains', value: 'Eigene' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result).to include(own_note)
        expect(result).not_to include(other_note)
      end
    end
  end

  describe '#sort_results (via build_results_query)' do
    context 'mit nil-Werten' do
      let!(:note_with_title) do
        create(:note, title: 'Zuerst', project: project, organisation: organisation,
                      creator: admin_user, updated_at: 1.day.ago)
      end
      let!(:note_nil_title) do
        note = create(:note, title: 'placeholder', project: project, organisation: organisation,
                             creator: admin_user, updated_at: 2.days.ago)
        note.update_column(:title, nil)
        note
      end

      it 'nutzt Fallback-Titel fuer Objekte ohne Titel bei Titel-Sortierung' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          sort_column: 'title',
          sort_direction: 'asc',
          rules_config: [
            [{ field: 'created_at', operator: 'in_the_last_days', value: '30' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result.size).to eq(2)
        # extract_title returns "Note <uuid>" for a nil title -> a valid sort string
        # "note ..." < "zuerst" (lowercase), so the nil-title note comes first under asc
        expect(result.map { |n| n.title || 'nil' }).to eq(%w[nil Zuerst])
      end
    end

    context 'sort_by Integer Fallback' do
      let!(:old_note) do
        create(:note, title: 'Alt', project: project, organisation: organisation,
                      creator: admin_user, created_at: 5.days.ago, updated_at: 5.days.ago)
      end
      let!(:new_note) do
        create(:note, title: 'Neu', project: project, organisation: organisation,
                      creator: admin_user, created_at: 1.day.ago, updated_at: 1.day.ago)
      end

      it 'nutzt sort_by Integer wenn sort_column nil ist (sort_by=3 -> created_at asc)' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          sort_column: nil,
          sort_direction: nil,
          sort_by: 3,
          rules_config: [
            [{ field: 'created_at', operator: 'in_the_last_days', value: '30' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result.first).to eq(old_note)
        expect(result.last).to eq(new_note)
      end

      it 'nutzt sort_by Integer fuer title_asc (sort_by=4)' do
        folder = create_smart_folder_with_rules(
          user: admin_user,
          sort_column: nil,
          sort_direction: nil,
          sort_by: 4,
          rules_config: [
            [{ field: 'created_at', operator: 'in_the_last_days', value: '30' }]
          ]
        )

        result = described_class.new(folder, admin_user).build_results_query

        expect(result.map(&:title)).to eq(%w[Alt Neu])
      end
    end
  end

  describe 'EAGER_LOADING' do
    it 'definiert Eager Loading fuer alle unterstuetzten Modelle' do
      SmartFolderQueryBuilder::SUPPORTED_MODELS.each_key do |model_name|
        expect(SmartFolderQueryBuilder::EAGER_LOADING).to have_key(model_name)
      end
    end
  end

  describe 'accessible_project_ids caching' do
    let!(:note) do
      create(:note, title: 'Cache', project: project, organisation: organisation, creator: admin_user)
    end

    it 'cached Projektzugriffs-IDs pro area+access_type' do
      folder = create_smart_folder_with_rules(
        user: regular_user,
        project_scope: nil,
        rules_config: [
          [{ field: 'title', operator: 'contains', value: 'Cache' }]
        ]
      )

      allow(AccessCheck::ProjectAccessService).to receive(:accessible_projects).and_return(Project.none)

      builder = described_class.new(folder, regular_user)
      builder.build_results_query

      expect(AccessCheck::ProjectAccessService).to have_received(:accessible_projects).at_most(:once)
    end
  end

  describe 'TimeSession permissions' do
    let!(:own_session) do
      create(:time_session,
             description: 'Eigene Session',
             project: project,
             organisation: organisation,
             creator: regular_user)
    end
    let!(:other_session) do
      create(:time_session,
             description: 'Fremde Session',
             project: project,
             organisation: organisation,
             creator: admin_user)
    end

    it 'Admin sieht alle TimeSessions' do
      folder = create_smart_folder_with_rules(
        user: admin_user,
        target_object_type: 'TimeSession',
        rules_config: [
          [{ field: 'created_at', operator: 'in_the_last_days', value: '30' }]
        ]
      )

      result = described_class.new(folder, admin_user).build_results_query

      expect(result).to include(own_session, other_session)
    end

    # The examples below run the REAL path, no stubs. The previous version
    # stubbed both ProjectAccessService AND a Pundit policy double with an
    # index_all_in_projects? method that does not exist on TimeSessionPolicy —
    # it green-lit an unreachable code path while the real one returned NONE for
    # every non-admin (:time_sessions is not a ProjectPermission area, so the
    # area-based project filter answered [] and the folder was silently empty).
    def time_folder_for(user)
      create_smart_folder_with_rules(
        user: user,
        target_object_type: 'TimeSession',
        project_scope: nil,
        rules_config: [
          [{ field: 'created_at', operator: 'in_the_last_days', value: '30' }]
        ]
      )
    end

    it 'can_view_own: sieht im Zeiten-Smart-Folder die eigenen Zeilen, nicht die fremden' do
      create(:time_session_permission, user: regular_user, project: project, can_view_own: true, can_view_all: false)

      result = described_class.new(time_folder_for(regular_user), regular_user).build_results_query

      expect(result).to include(own_session)
      expect(result).not_to include(other_session)
    end

    it 'can_view_all: sieht eigene und fremde Zeilen' do
      create(:time_session_permission, user: regular_user, project: project, can_view_own: true, can_view_all: true)

      result = described_class.new(time_folder_for(regular_user), regular_user).build_results_query

      expect(result).to include(own_session, other_session)
    end

    it 'ohne Permission-Zeile: leer, aber kein Fehler' do
      result = described_class.new(time_folder_for(regular_user), regular_user).build_results_query

      expect(result).to be_empty
    end
  end

  describe 'error resilience' do
    it 'faengt AccessCheck::ProjectAccessService NameError ab' do
      folder = create_smart_folder_with_rules(
        user: regular_user,
        project_scope: nil,
        rules_config: [
          [{ field: 'title', operator: 'contains', value: 'Test' }]
        ]
      )

      allow(AccessCheck::ProjectAccessService).to receive(:accessible_projects)
        .and_raise(NameError, 'uninitialized constant')

      allow(Rails.logger).to receive(:error)

      result = described_class.new(folder, regular_user).build_results_query

      expect(result).to eq([])
      expect(Rails.logger).to have_received(:error).with(/uninitialized constant/)
    end

    it 'uebergeht Gruppen bei fehlenden Treffern und verarbeitet andere Gruppen weiter' do
      note = create(:note, title: 'Rettung', project: project, organisation: organisation, creator: admin_user)

      folder = create_smart_folder_with_rules(
        user: admin_user,
        rules_config: [
          [{ field: 'title', operator: 'contains', value: 'NichtDa' }],
          [{ field: 'title', operator: 'contains', value: 'Rettung' }]
        ]
      )

      result = described_class.new(folder, admin_user).build_results_query

      expect(result).to include(note)
    end

    it 'loggt Warnung wenn RESULTS_PER_MODEL_LIMIT erreicht wird' do
      folder = create_smart_folder_with_rules(
        user: admin_user,
        rules_config: [
          [{ field: 'created_at', operator: 'in_the_last_days', value: '9999' }]
        ]
      )

      allow(Rails.logger).to receive(:warn)

      stub_const('SmartFolderQueryBuilder::RESULTS_PER_MODEL_LIMIT', 1)
      create(:note, title: 'A', project: project, organisation: organisation, creator: admin_user)
      create(:note, title: 'B', project: project, organisation: organisation, creator: admin_user)

      described_class.new(folder, admin_user).build_results_query

      expect(Rails.logger).to have_received(:warn).with(/query limit.*reached/)
    end
  end

  describe 'extract_title' do
    let(:builder) { described_class.new(create(:smart_folder, user: admin_user, organisation: organisation, project: project)) }

    it 'nutzt title wenn vorhanden' do
      note = build(:note, title: 'Mein Titel')
      expect(builder.send(:extract_title, note)).to eq('Mein Titel')
    end

    it 'faellt auf Klassenname + ID zurueck wenn kein Titel' do
      item = double('Item', id: 'abc-123')
      allow(item).to receive(:respond_to?).with(:title).and_return(false)
      allow(item).to receive(:respond_to?).with(:current_version).and_return(false)
      allow(item).to receive(:respond_to?).with(:name).and_return(false)
      allow(item).to receive(:respond_to?).with(:description).and_return(false)
      allow(item).to receive(:is_a?).and_return(false)
      allow(item).to receive_message_chain(:class, :name).and_return('Widget')

      expect(builder.send(:extract_title, item)).to eq('Widget abc-123')
    end
  end

  describe '#filter_relation' do
    let(:other_project) { create(:project, organisation: organisation) }

    def folder_with_title_rule(target:, operator:, value:, project_scope: project)
      create(:smart_folder, organisation: organisation, project: project_scope, user: admin_user, target_object_type: target).tap do |folder|
        folder.smart_folder_rule_groups.create!(position: 1)
              .smart_folder_rules.create!(field: 'title', operator: operator, value: value, position: 1)
      end
    end

    it 'never applies a view to a model it does not target' do
      create(:meeting, organisation: organisation, project: project, creator: admin_user, title: 'Meeting')
      folder = folder_with_title_rule(target: 'Ticket', operator: 'contains', value: 'Meeting')
      expect(described_class.new(folder, admin_user).filter_relation(project.meetings)).to be_empty
    end

    it 'applies a project-bound view only inside its own project' do
      ticket = create(:ticket, project: project, organisation: organisation, creator: admin_user, title: 'Match')
      folder = folder_with_title_rule(target: 'Ticket', operator: 'equals', value: 'Match', project_scope: other_project)
      expect(described_class.new(folder, admin_user).filter_relation(project.tickets).pluck(:id)).not_to include(ticket.id)
    end
  end
end
