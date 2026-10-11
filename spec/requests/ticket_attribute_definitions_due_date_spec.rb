# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Ticket attribute definitions: deadline marker + level preservation', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { ActsAsTenant.with_tenant(organisation) { create(:user) } }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { sign_in user }

  describe 'creating a date field with the deadline marker' do
    it 'marks the date field as the deadline when checked' do
      post organisation_project_ticket_attribute_definitions_path(organisation, project),
           params: { ticket_attribute_definition: { field_type: 'date', labels: { de: 'Fälligkeit', en: 'Due date' }, deadline: '1' } }

      definition = project.ticket_attribute_definitions.find_by(field_type: 'date')
      expect(definition).to be_present
      expect(definition.deadline?).to be(true)
    end

    it 'does not mark it when the checkbox is off (hidden 0 submitted)' do
      post organisation_project_ticket_attribute_definitions_path(organisation, project),
           params: { ticket_attribute_definition: { field_type: 'date', labels: { de: 'Wunschtermin', en: 'Target' }, deadline: '0' } }

      definition = project.ticket_attribute_definitions.where(field_type: 'date').last
      expect(definition.deadline?).to be(false)
    end
  end

  describe 'editing a leveled select' do
    let!(:priority) do
      ActsAsTenant.with_tenant(organisation) do
        project.ticket_attribute_definitions.create!(
          name: 'priority', field_type: 'select', width: 'half',
          labels: { 'de' => 'Priorität', 'en' => 'Priority' },
          options: { 'allowed_values' => [
            { 'value' => 'low', 'labels' => { 'de' => 'Niedrig', 'en' => 'Low' }, 'level' => 1, 'color' => '#93C5FD' },
            { 'value' => 'high', 'labels' => { 'de' => 'Hoch', 'en' => 'High' }, 'level' => 2, 'color' => '#F97316' }
          ] }
        )
      end
    end

    it 'preserves configured signal-bar levels across an unrelated edit (recolor)' do
      patch organisation_project_ticket_attribute_definition_path(organisation, project, priority),
            params: { ticket_attribute_definition: { field_type: 'select', options: %w[low high], option_colors: ['#000000', '#111111'] } }

      expect(priority.reload.allowed_values.map { |opt| opt['level'] }).to eq([1, 2])
    end
  end
end
