# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SystemFunctions::Resolver do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user) }

  before { ActsAsTenant.current_tenant = organisation }

  let!(:status_definition) do
    create(:ticket_attribute_definition,
           project: project,
           name: 'status',
           field_type: 'select',
           options: {
             'allowed_values' => [
               { 'value' => 'Neu', 'labels' => { 'de' => 'Neu' }, 'color' => '#11ee14', 'system_functions' => ['is_new'] },
               { 'value' => 'In Bearbeitung', 'labels' => { 'de' => 'In Bearbeitung' }, 'color' => '#ffcc00', 'system_functions' => ['is_in_progress'] },
               { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'color' => '#22bb33', 'system_functions' => ['is_completed'] },
               { 'value' => 'Geschlossen', 'labels' => { 'de' => 'Geschlossen' }, 'color' => '#888888', 'system_functions' => ['is_closed'] }
             ]
           })
  end

  let!(:priority_definition) do
    create(:ticket_attribute_definition,
           project: project,
           name: 'priority',
           field_type: 'select',
           options: {
             'allowed_values' => [
               { 'value' => 'Hoch', 'labels' => { 'de' => 'Hoch' }, 'color' => '#ff0000', 'system_functions' => %w[high_priority highlight_container] },
               { 'value' => 'Normal', 'labels' => { 'de' => 'Normal' }, 'color' => '#ffcc00' },
               { 'value' => 'Niedrig', 'labels' => { 'de' => 'Niedrig' }, 'color' => '#0000ff' }
             ]
           })
  end

  describe '#active_functions' do
    it 'returns empty set when ticket has no custom attributes' do
      ticket = create(:ticket, project: project, creator: user, organisation: organisation)

      resolver = described_class.new(ticket)
      expect(resolver.active_functions).to be_empty
    end

    it 'returns matching system functions for selected status' do
      ticket = create(:ticket, project: project, creator: user, organisation: organisation,
                               custom_attributes: { 'status' => 'Neu' })

      resolver = described_class.new(ticket)
      expect(resolver.active_functions).to include('is_new')
    end

    it 'returns functions from multiple attributes' do
      ticket = create(:ticket, project: project, creator: user, organisation: organisation,
                               custom_attributes: { 'status' => 'Neu', 'priority' => 'Hoch' })

      resolver = described_class.new(ticket)
      expect(resolver.active_functions).to include('is_new', 'high_priority', 'highlight_container')
    end

    it 'returns empty set when selected value has no system functions' do
      ticket = create(:ticket, project: project, creator: user, organisation: organisation,
                               custom_attributes: { 'priority' => 'Normal' })

      resolver = described_class.new(ticket)
      expect(resolver.active_functions).to be_empty
    end

    it 'handles option values with multiple system functions' do
      ticket = create(:ticket, project: project, creator: user, organisation: organisation,
                               custom_attributes: { 'priority' => 'Hoch' })

      resolver = described_class.new(ticket)
      expect(resolver.active_functions).to include('high_priority', 'highlight_container')
    end

    it 'ignores non-option field types' do
      create(:ticket_attribute_definition,
             project: project,
             name: 'description',
             field_type: 'text')

      ticket = create(:ticket, project: project, creator: user, organisation: organisation,
                               custom_attributes: { 'description' => 'Some text' })

      resolver = described_class.new(ticket)
      expect(resolver.active_functions).to be_empty
    end
  end

  describe '#has?' do
    it 'returns true when function is active' do
      ticket = create(:ticket, project: project, creator: user, organisation: organisation,
                               custom_attributes: { 'status' => 'Neu' })

      resolver = described_class.new(ticket)
      expect(resolver.has?('is_new')).to be true
    end

    it 'returns false when function is not active' do
      ticket = create(:ticket, project: project, creator: user, organisation: organisation,
                               custom_attributes: { 'status' => 'Neu' })

      resolver = described_class.new(ticket)
      expect(resolver.has?('is_completed')).to be false
    end

    it 'accepts symbols' do
      ticket = create(:ticket, project: project, creator: user, organisation: organisation,
                               custom_attributes: { 'status' => 'Neu' })

      resolver = described_class.new(ticket)
      expect(resolver.has?(:is_new)).to be true
    end
  end

  context 'with multiselect field' do
    let!(:tags_definition) do
      create(:ticket_attribute_definition,
             project: project,
             name: 'tags',
             field_type: 'multiselect',
             options: {
               'allowed_values' => [
                 { 'value' => 'urgent', 'labels' => { 'de' => 'Dringend' }, 'system_functions' => ['high_priority'] },
                 { 'value' => 'done', 'labels' => { 'de' => 'Fertig' }, 'system_functions' => ['is_completed'] },
                 { 'value' => 'normal', 'labels' => { 'de' => 'Normal' } }
               ]
             })
    end

    it 'resolves functions from multiselect values' do
      ticket = create(:ticket, project: project, creator: user, organisation: organisation,
                               custom_attributes: { 'tags' => %w[urgent done] })

      resolver = described_class.new(ticket)
      expect(resolver.active_functions).to include('high_priority', 'is_completed')
    end
  end

  context 'with duplicate functions across options' do
    it 'deduplicates functions when multiple options map to the same function' do
      # Both "Erledigt" and "Abgeschlossen" map to is_completed
      create(:ticket_attribute_definition,
             project: project,
             name: 'workflow',
             field_type: 'select',
             options: {
               'allowed_values' => [
                 { 'value' => 'Erledigt', 'labels' => { 'de' => 'Erledigt' }, 'system_functions' => ['is_completed'] },
                 { 'value' => 'Abgeschlossen', 'labels' => { 'de' => 'Abgeschlossen' }, 'system_functions' => ['is_completed'] }
               ]
             })

      ticket = create(:ticket, project: project, creator: user, organisation: organisation,
                               custom_attributes: { 'status' => 'Erledigt', 'workflow' => 'Abgeschlossen' })

      resolver = described_class.new(ticket)
      # Set deduplicates — is_completed appears only once
      expect(resolver.active_functions).to include('is_completed')
      expect(resolver.active_functions.size).to eq(resolver.active_functions.to_a.uniq.size)
    end
  end
end
