# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SmartFolderService, type: :service do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:owner) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  let(:smart_folder) do
    create(:smart_folder,
           organisation: organisation,
           user: owner,
           project: project,
           target_object_type: 'Note')
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: owner, organisation: organisation, role: admin_role)
  end

  describe '#initialize' do
    it 'setzt current_user auf den übergebenen User' do
      other_user = create(:user)
      create(:membership, user: other_user, organisation: organisation, role: admin_role)
      service = described_class.new(smart_folder, other_user)

      expect(service.current_user).to eq(other_user)
    end

    it 'fällt auf smart_folder.user zurück wenn kein User übergeben' do
      service = described_class.new(smart_folder)

      expect(service.current_user).to eq(owner)
    end
  end

  describe '#fetch_results' do
    subject(:service) { described_class.new(smart_folder, owner) }

    context 'Zugriffskontrolle' do
      it 'gibt leeres Ergebnis zurück wenn User keinen Zugriff hat' do
        unauthorized_user = create(:user)
        # No membership → no access
        service = described_class.new(smart_folder, unauthorized_user)

        result = service.fetch_results

        expect(result[:items]).to be_empty
        expect(result[:total]).to eq(0)
        expect(result[:page]).to eq(1)
      end

      it 'gibt leeres Ergebnis zurück wenn current_user nil ist' do
        # accessible_by?(nil) → false according to the SmartFolder model
        service = described_class.new(smart_folder, nil)
        # current_user falls back to owner, but we are testing accessible_by?
        # To force nil, we have to mock the service
        allow(smart_folder).to receive(:accessible_by?).with(owner).and_return(false)

        result = service.fetch_results

        expect(result[:items]).to be_empty
        expect(result[:total]).to eq(0)
      end

      it 'gibt Ergebnisse zurück für den Owner' do
        rule_group = create(:smart_folder_rule_group, smart_folder: smart_folder)
        create(:smart_folder_rule,
               smart_folder_rule_group: rule_group,
               field: 'title',
               operator: 'contains',
               value: 'Test')
        create(:note, title: 'Test Note', project: project, organisation: organisation, creator: owner)

        result = service.fetch_results

        expect(result[:items]).not_to be_empty
      end

      context 'mit shared Folder' do
        let(:shared_user) { create(:user) }

        before do
          create(:membership, user: shared_user, organisation: organisation, role: admin_role)
          smart_folder.share_with(shared_user)
        end

        it 'erlaubt Zugriff für User mit Share' do
          rule_group = create(:smart_folder_rule_group, smart_folder: smart_folder)
          create(:smart_folder_rule,
                 smart_folder_rule_group: rule_group,
                 field: 'title',
                 operator: 'contains',
                 value: 'Shared')
          create(:note, title: 'Shared Note', project: project, organisation: organisation, creator: owner)

          shared_service = described_class.new(smart_folder, shared_user)
          result = shared_service.fetch_results

          expect(result[:items]).not_to be_empty
        end
      end

      context 'mit öffentlichem Folder' do
        let(:public_folder) do
          create(:smart_folder,
                 organisation: organisation,
                 user: owner,
                 project: project,
                 target_object_type: 'Note',
                 is_public: true)
        end

        it 'erlaubt Zugriff für jeden Org-User' do
          other_user = create(:user)
          create(:membership, user: other_user, organisation: organisation, role: admin_role)
          rule_group = create(:smart_folder_rule_group, smart_folder: public_folder)
          create(:smart_folder_rule,
                 smart_folder_rule_group: rule_group,
                 field: 'title',
                 operator: 'contains',
                 value: 'Public')
          create(:note, title: 'Public Test', project: project, organisation: organisation, creator: owner)

          public_service = described_class.new(public_folder, other_user)
          result = public_service.fetch_results

          expect(result[:items]).not_to be_empty
        end
      end
    end

    context 'Pagination' do
      before do
        rule_group = create(:smart_folder_rule_group, smart_folder: smart_folder)
        create(:smart_folder_rule,
               smart_folder_rule_group: rule_group,
               field: 'title',
               operator: 'contains',
               value: 'Paginated')
        10.times do |i|
          create(:note,
                 title: "Paginated Note #{i}",
                 project: project,
                 organisation: organisation,
                 creator: owner)
        end
      end

      it 'liefert ohne Options alle Treffer ungecappt (page=1, per_page=total)' do
        result = service.fetch_results

        expect(result[:page]).to eq(1)
        expect(result[:per_page]).to eq(10)
        expect(result[:total]).to eq(10)
        expect(result[:items].size).to eq(10)
      end

      it 'paginiert korrekt mit page und per_page' do
        result = service.fetch_results(page: 1, per_page: 3)

        expect(result[:items].size).to eq(3)
        expect(result[:total]).to eq(10)
        expect(result[:page]).to eq(1)
        expect(result[:per_page]).to eq(3)
      end

      it 'gibt zweite Seite korrekt zurück' do
        result = service.fetch_results(page: 2, per_page: 3)

        expect(result[:items].size).to eq(3)
        expect(result[:page]).to eq(2)
      end

      it 'gibt letzte (unvollständige) Seite korrekt zurück' do
        result = service.fetch_results(page: 4, per_page: 3)

        expect(result[:items].size).to eq(1)
        expect(result[:page]).to eq(4)
      end

      it 'gibt leere items bei Seite jenseits der Ergebnisse zurück' do
        result = service.fetch_results(page: 100, per_page: 25)

        expect(result[:items]).to be_empty
        expect(result[:total]).to eq(10)
        expect(result[:page]).to eq(100)
      end
    end

    context 'Page Normalisierung (Edge Cases)' do
      it 'normalisiert page=0 auf 1' do
        result = service.fetch_results(page: 0)

        expect(result[:page]).to eq(1)
      end

      it 'normalisiert negative page auf 1' do
        result = service.fetch_results(page: -5)

        expect(result[:page]).to eq(1)
      end

      it 'normalisiert nil page auf 1' do
        result = service.fetch_results(page: nil)

        expect(result[:page]).to eq(1)
      end

      it 'normalisiert String page korrekt' do
        result = service.fetch_results(page: '3')

        expect(result[:page]).to eq(3)
      end

      it 'normalisiert ungültigen String page auf 1' do
        result = service.fetch_results(page: 'abc')

        expect(result[:page]).to eq(1)
      end
    end

    context 'Per-Page Normalisierung (Edge Cases)' do
      it 'normalisiert per_page=0 auf Default' do
        result = service.fetch_results(per_page: 0)

        expect(result[:per_page]).to eq(SmartFolderService::DEFAULT_PER_PAGE)
      end

      it 'normalisiert negative per_page auf Default' do
        result = service.fetch_results(per_page: -10)

        expect(result[:per_page]).to eq(SmartFolderService::DEFAULT_PER_PAGE)
      end

      it 'behandelt nil per_page wie nicht uebergeben (ungecappt)' do
        result = service.fetch_results(per_page: nil)

        expect(result[:per_page]).to eq(result[:total])
        expect(result[:items].size).to eq(result[:total])
      end

      it 'begrenzt per_page auf MAX_PER_PAGE' do
        result = service.fetch_results(per_page: 500)

        expect(result[:per_page]).to eq(SmartFolderService::MAX_PER_PAGE)
      end

      it 'erlaubt per_page bis MAX_PER_PAGE' do
        result = service.fetch_results(per_page: SmartFolderService::MAX_PER_PAGE)

        expect(result[:per_page]).to eq(SmartFolderService::MAX_PER_PAGE)
      end

      it 'normalisiert ungültigen String per_page auf Default' do
        result = service.fetch_results(per_page: 'xyz')

        expect(result[:per_page]).to eq(SmartFolderService::DEFAULT_PER_PAGE)
      end
    end

    context 'Leere Ergebnisse' do
      it 'gibt leere items zurück wenn keine Regel-Gruppen existieren' do
        # smart_folder has no rule_groups
        result = service.fetch_results

        expect(result[:items]).to be_empty
        expect(result[:total]).to eq(0)
      end

      it 'gibt leere items zurück wenn keine passenden Objekte existieren' do
        rule_group = create(:smart_folder_rule_group, smart_folder: smart_folder)
        create(:smart_folder_rule,
               smart_folder_rule_group: rule_group,
               field: 'title',
               operator: 'contains',
               value: 'NiemalsVorhandenerTitel12345')

        result = service.fetch_results

        expect(result[:items]).to be_empty
        expect(result[:total]).to eq(0)
      end
    end

    context 'Ergebnis-Struktur' do
      it 'gibt immer :items, :total, :page, :per_page zurück' do
        result = service.fetch_results

        expect(result).to have_key(:items)
        expect(result).to have_key(:total)
        expect(result).to have_key(:page)
        expect(result).to have_key(:per_page)
      end

      it 'gibt konsistente Struktur bei Access Denied zurück' do
        allow(smart_folder).to receive(:accessible_by?).and_return(false)

        result = service.fetch_results(per_page: 10)

        expect(result).to eq({ items: [], total: 0, page: 1, per_page: 10 })
      end

      it 'items ist immer ein Array, nie nil' do
        result = service.fetch_results

        expect(result[:items]).to be_an(Array)
      end
    end

    context 'QueryBuilder-Integration' do
      it 'delegiert die Query an den QueryBuilder' do
        query_builder = instance_double(SmartFolderQueryBuilder, build_results_query: [])
        allow(SmartFolderQueryBuilder).to receive(:new).and_return(query_builder)

        service = described_class.new(smart_folder, owner)
        service.fetch_results

        expect(query_builder).to have_received(:build_results_query)
      end

      it 'übergibt current_user an QueryBuilder' do
        allow(SmartFolderQueryBuilder).to receive(:new).and_call_original

        described_class.new(smart_folder, owner)

        expect(SmartFolderQueryBuilder).to have_received(:new).with(smart_folder, owner)
      end
    end
  end

  describe 'Konstanten' do
    it 'definiert DEFAULT_PER_PAGE als 25' do
      expect(SmartFolderService::DEFAULT_PER_PAGE).to eq(25)
    end

    it 'definiert MAX_PER_PAGE als 100' do
      expect(SmartFolderService::MAX_PER_PAGE).to eq(100)
    end
  end
  describe '#fetch_results Pagination' do
    subject(:service) { described_class.new(smart_folder, owner) }

    before do
      rule_group = create(:smart_folder_rule_group, smart_folder: smart_folder)
      create(:smart_folder_rule,
             smart_folder_rule_group: rule_group,
             field: 'title',
             operator: 'contains',
             value: 'Cap')
      30.times do |i|
        create(:note, title: "Cap Note #{i}", project: project, organisation: organisation, creator: owner)
      end
    end

    it 'liefert ohne Pagination-Options ALLE Treffer (Regression: implizites 25er-Default beschnitt Folder-Filter still)' do
      result = service.fetch_results

      expect(result[:items].size).to eq(30)
      expect(result[:total]).to eq(30)
    end

    it 'paginiert weiterhin bei expliziten Options' do
      result = service.fetch_results(page: 2, per_page: 10)

      expect(result[:items].size).to eq(10)
      expect(result[:total]).to eq(30)
    end

    it 'paginiert mit Default-Seitengroesse, wenn nur page uebergeben wird' do
      result = service.fetch_results(page: 1)

      expect(result[:items].size).to eq(SmartFolderService::DEFAULT_PER_PAGE)
    end
  end
end
