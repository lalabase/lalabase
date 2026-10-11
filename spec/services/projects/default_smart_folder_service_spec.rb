# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Projects::DefaultSmartFolderService do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:project_permission) { create(:project_permission, user: user, project: project) }
  let(:priority_attribute) do
    create(:ticket_attribute_definition, :select,
           project: project,
           name: 'priority',
           options: {
             'allowed_values' => [
               { 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' } },
               { 'value' => 'medium', 'labels' => { 'de' => 'Mittel', 'en' => 'Medium' } },
               { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' } },
               { 'value' => 'urgent', 'labels' => { 'de' => 'Dringend', 'en' => 'Urgent' } }
             ]
           })
  end

  let(:service) { described_class.new(project) }

  before do
    ActsAsTenant.current_tenant = organisation
    project_permission
    priority_attribute
  end

  after { ActsAsTenant.current_tenant = nil }

  describe '#call' do
    subject(:call_service) { service.call(user) }

    context 'when no smart folders exist yet (happy path)' do
      it 'creates exactly 5 smart folders' do
        expect { call_service }.to change { project.smart_folders.count }.by(5)
      end

      it 'creates the "Meine Aufgaben" folder as private' do
        call_service
        folder = project.smart_folders.find_by(name: I18n.t('services.default_smart_folder.my_tasks'))

        expect(folder).to have_attributes(
          user: user,
          is_public: false,
          public_access_level: 0,
          target_object_type: 'Ticket'
        )
      end

      it 'creates "Meine Aufgaben" with an assignee rule pointing to the user' do
        call_service
        folder = project.smart_folders.find_by(name: I18n.t('services.default_smart_folder.my_tasks'))
        rules = folder.smart_folder_rules

        expect(rules.count).to eq(1)
        expect(rules.first).to have_attributes(
          field: 'assignee',
          operator: 'equals',
          value: user.id.to_s
        )
      end

      it 'creates "Hohe Priorität" as public with two rule groups' do
        call_service
        folder = project.smart_folders.find_by(name: I18n.t('services.default_smart_folder.high_priority'))

        expect(folder).to have_attributes(is_public: true, public_access_level: 1)
        expect(folder.smart_folder_rule_groups.count).to eq(2)

        rules = folder.smart_folder_rules.order(:position)
        expect(rules.map { |r| [r.field, r.operator, r.value] }).to contain_exactly(
          %w[custom_priority equals high],
          %w[custom_priority equals urgent]
        )
      end

      it 'creates "Kürzlich erstellt" with sort by created_at desc' do
        call_service
        folder = project.smart_folders.find_by(name: I18n.t('services.default_smart_folder.recently_created'))

        expect(folder).to have_attributes(
          is_public: true,
          sort_column: 'created_at',
          sort_direction: 'desc'
        )

        rule = folder.smart_folder_rules.first
        expect(rule).to have_attributes(
          field: 'created_at',
          operator: 'in_the_last_days',
          value: '7'
        )
      end

      it 'creates "Kürzlich aktualisiert" with sort by updated_at desc' do
        call_service
        folder = project.smart_folders.find_by(name: I18n.t('services.default_smart_folder.recently_updated'))

        expect(folder).to have_attributes(
          is_public: true,
          sort_column: 'updated_at',
          sort_direction: 'desc'
        )

        rule = folder.smart_folder_rules.first
        expect(rule).to have_attributes(
          field: 'updated_at',
          operator: 'in_the_last_days',
          value: '7'
        )
      end

      it 'creates "Nicht berechnet" with two rules in one group' do
        call_service
        folder = project.smart_folders.find_by(name: I18n.t('services.default_smart_folder.unbilled'))

        expect(folder).to have_attributes(is_public: true)
        expect(folder.smart_folder_rule_groups.count).to eq(1)

        rules = folder.smart_folder_rules.order(:position)
        expect(rules.count).to eq(2)
        expect(rules.map { |r| [r.field, r.operator, r.value] }).to eq([
                                                                         %w[has_time_sessions is true],
                                                                         %w[time_session_billed is_not true]
                                                                       ])
      end

      it 'sets the organisation on all created folders' do
        call_service
        project.smart_folders.each do |folder|
          expect(folder.organisation).to eq(organisation)
        end
      end
    end

    context 'idempotency — calling twice' do
      it 'does not create duplicate folders' do
        service.call(user)

        expect { service.call(user) }.not_to(change { project.smart_folders.count })
      end

      it 'does not create duplicate rule groups or rules' do
        service.call(user)
        rule_count_before = SmartFolderRule.count
        group_count_before = SmartFolderRuleGroup.count

        service.call(user)

        expect(SmartFolderRule.count).to eq(rule_count_before)
        expect(SmartFolderRuleGroup.count).to eq(group_count_before)
      end
    end

    context 'partial idempotency — some folders already exist' do
      before do
        service.send(:create_my_tasks, user)
      end

      it 'creates only the missing 4 folders' do
        expect { call_service }.to change { project.smart_folders.count }.by(4)
      end

      it 'does not duplicate the existing my_tasks folder' do
        call_service
        my_tasks_count = project.smart_folders.where(
          name: I18n.t('services.default_smart_folder.my_tasks'),
          user: user
        ).count

        expect(my_tasks_count).to eq(1)
      end
    end

    context 'when custom_priority attribute does not exist' do
      before { priority_attribute.destroy! }

      it 'skips the high priority folder gracefully' do
        expect { call_service }.to change { project.smart_folders.count }.by(4)
      end

      it 'does not create the high priority folder' do
        call_service
        folder = project.smart_folders.find_by(name: I18n.t('services.default_smart_folder.high_priority'))
        expect(folder).to be_nil
      end

      it 'still creates all other folders' do
        call_service
        names = project.smart_folders.pluck(:name)
        expect(names).to include(
          I18n.t('services.default_smart_folder.my_tasks'),
          I18n.t('services.default_smart_folder.recently_created'),
          I18n.t('services.default_smart_folder.recently_updated'),
          I18n.t('services.default_smart_folder.unbilled')
        )
      end
    end

    context 'system_user resolution' do
      let(:other_user) { create(:user, organisation: organisation) }

      it 'uses the first project permission holder as system_user for public folders' do
        call_service
        public_folders = project.smart_folders.where(is_public: true).includes(:user)

        public_folders.each do |folder|
          expect(folder.user).to eq(user)
        end
      end

      context 'when project has no project_permissions' do
        before { project.project_permissions.destroy_all }

        it 'falls back to organisation.users.first' do
          call_service
          public_folders = project.smart_folders.where(is_public: true).includes(:user)
          fallback_user = organisation.users.first

          public_folders.each do |folder|
            expect(folder.user).to eq(fallback_user)
          end
        end
      end

      context 'when multiple project_permissions exist' do
        let!(:earlier_permission) do
          create(:project_permission, user: other_user, project: project, created_at: 1.day.ago)
        end

        it 'uses the user from the earliest permission' do
          call_service
          public_folder = project.smart_folders.find_by(
            name: I18n.t('services.default_smart_folder.high_priority')
          )

          expect(public_folder.user).to eq(other_user)
        end
      end

      context 'when neither project_permissions nor organisation users exist' do
        before do
          project.project_permissions.destroy_all
          organisation.users.destroy_all
        end

        it 'raises NoSystemUserError with a descriptive message' do
          expect { call_service }.to raise_error(
            described_class::NoSystemUserError,
            /No system user found for project/
          )
        end
      end
    end
  end

  describe '#create_my_tasks_for' do
    subject(:create_my_tasks) { service.create_my_tasks_for(user) }

    it 'creates only one smart folder' do
      expect { create_my_tasks }.to change { project.smart_folders.count }.by(1)
    end

    it 'creates a private "Meine Aufgaben" folder for the given user' do
      create_my_tasks
      folder = project.smart_folders.find_by(user: user, name: I18n.t('services.default_smart_folder.my_tasks'))

      expect(folder).to be_present
      expect(folder.is_public).to be(false)
    end

    it 'does not create any public folders' do
      create_my_tasks
      expect(project.smart_folders.where(is_public: true).count).to eq(0)
    end

    context 'idempotency' do
      it 'does not create a duplicate when called twice for the same user' do
        service.create_my_tasks_for(user)

        expect { service.create_my_tasks_for(user) }.not_to(change { project.smart_folders.count })
      end
    end

    context 'multiple users' do
      let(:other_user) { create(:user, organisation: organisation) }
      let!(:other_permission) { create(:project_permission, user: other_user, project: project) }

      it 'creates separate folders per user' do
        service.create_my_tasks_for(user)
        service.create_my_tasks_for(other_user)

        my_tasks_folders = project.smart_folders.where(
          name: I18n.t('services.default_smart_folder.my_tasks')
        )

        expect(my_tasks_folders.count).to eq(2)
        expect(my_tasks_folders.pluck(:user_id)).to contain_exactly(user.id, other_user.id)
      end

      it 'creates user-specific assignee rules' do
        service.create_my_tasks_for(user)
        service.create_my_tasks_for(other_user)

        user_folder = project.smart_folders.find_by(
          name: I18n.t('services.default_smart_folder.my_tasks'),
          user: user
        )
        other_folder = project.smart_folders.find_by(
          name: I18n.t('services.default_smart_folder.my_tasks'),
          user: other_user
        )

        expect(user_folder.smart_folder_rules.first.value).to eq(user.id.to_s)
        expect(other_folder.smart_folder_rules.first.value).to eq(other_user.id.to_s)
      end
    end
  end

  describe 'i18n folder names' do
    it 'uses translated names from the locale file' do
      service.call(user)

      expected_names = %i[my_tasks high_priority recently_created recently_updated unbilled].map do |key|
        I18n.t("services.default_smart_folder.#{key}")
      end

      actual_names = project.smart_folders.pluck(:name)
      expect(actual_names).to match_array(expected_names)
    end

    it 'resolves German locale names correctly' do
      I18n.with_locale(:de) do
        service.call(user)
        names = project.smart_folders.pluck(:name)
        expect(names).to include('Meine Aufgaben', 'Hohe Priorität', 'Nicht berechnet')
      end
    end
  end

  describe 'rule structure integrity' do
    before { service.call(user) }

    it 'assigns sequential positions to rule groups within each folder' do
      project.smart_folders.includes(:smart_folder_rule_groups).each do |folder|
        positions = folder.smart_folder_rule_groups.map(&:position)
        expect(positions).to eq(positions.sort)
        expect(positions.uniq).to eq(positions)
      end
    end

    it 'sets target_object_type to Ticket on all folders' do
      project.smart_folders.each do |folder|
        expect(folder.target_object_type).to eq('Ticket')
      end
    end
  end
end
