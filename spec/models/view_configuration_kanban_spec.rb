# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ViewConfiguration, 'kanban support' do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
  end

  let(:view_config) do
    ViewConfiguration.for_user_project(user, project, 'tickets').tap do |vc|
      vc.organisation = organisation
      vc.save!
    end
  end

  describe 'VIEW_MODES' do
    it 'includes table and kanban' do
      expect(ViewConfiguration::VIEW_MODES).to eq(%w[table kanban])
    end
  end

  describe '#kanban_mode?' do
    it 'returns true when view_mode is kanban' do
      view_config.update!(view_mode: 'kanban')
      expect(view_config.kanban_mode?).to be true
    end

    it 'returns false for table mode' do
      expect(view_config.kanban_mode?).to be false
    end
  end

  describe '#kanban_eligible_attributes' do
    it 'returns only select attributes' do
      select_attr = create(:ticket_attribute_definition, :select, project: project, name: 'status')
      create(:ticket_attribute_definition, project: project, name: 'description', field_type: 'text')
      create(:ticket_attribute_definition, :checkbox, project: project, name: 'urgent')

      eligible = view_config.kanban_eligible_attributes
      expect(eligible).to contain_exactly(select_attr)
    end

    it 'excludes inactive attributes' do
      create(:ticket_attribute_definition, :select, project: project, name: 'status', active: false)
      expect(view_config.kanban_eligible_attributes).to be_empty
    end
  end

  describe '#resolved_kanban_attribute' do
    let!(:status_attr) do
      create(:ticket_attribute_definition, project: project, name: 'status', field_type: 'select',
                                           options: {
                                             'allowed_values' => [
                                               { 'value' => 'Neu', 'labels' => {}, 'system_functions' => ['is_new'] },
                                               { 'value' => 'Erledigt', 'labels' => {}, 'system_functions' => ['is_completed'] }
                                             ]
                                           })
    end

    context 'with explicit kanban_attribute_definition' do
      let!(:other_attr) do
        create(:ticket_attribute_definition, :select, project: project, name: 'category')
      end

      it 'returns explicit attribute over auto-detect' do
        view_config.update!(kanban_attribute_definition: other_attr)
        expect(view_config.resolved_kanban_attribute).to eq(other_attr)
      end
    end

    context 'without explicit attribute' do
      it 'auto-detects attribute with status system functions' do
        expect(view_config.resolved_kanban_attribute).to eq(status_attr)
      end
    end

    context 'with no eligible attributes' do
      it 'returns nil' do
        TicketAttributeDefinition.where(project: project).destroy_all
        expect(view_config.resolved_kanban_attribute).to be_nil
      end
    end
  end

  describe 'validations' do
    it 'allows valid view_modes' do
      %w[table kanban].each do |mode|
        view_config.view_mode = mode
        expect(view_config).to be_valid
      end
    end

    it 'rejects invalid view_mode' do
      view_config.view_mode = 'grid'
      expect(view_config).not_to be_valid
    end

    it 'allows nil view_mode' do
      view_config.view_mode = nil
      expect(view_config).to be_valid
    end
  end
end
