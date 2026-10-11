# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NeoActivityFilterComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation:) }
  let(:user) { create(:user, first_name: 'Gabi', last_name: 'Boyke') }
  let(:filter_url) { organisation_project_activities_path(organisation, project) }
  let(:current_filters) { {} }

  subject(:component) do
    described_class.new(current_filters:, filter_url:, result_count: 20, project:)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user:, organisation:, active: true)
  end

  after { ActsAsTenant.current_tenant = nil }

  def rendered_component
    render_inline(component)
  end

  it 'renders tabs, an immediate filter menu, search and result count without native selects' do
    rendered_component

    expect(page).to have_css('[data-testid="activity-filter-bar"]')
    expect(page).to have_link('Alles', href: filter_url)
    expect(page).to have_link('Von mir')
    expect(page).to have_link('Nur Tickets')
    expect(page).to have_css('summary', text: 'Filter')
    expect(page).to have_field('q', type: 'search')
    expect(page).to have_content('20 Aktivitäten', normalize_ws: true)
    expect(page).not_to have_css('select')
    expect(page).not_to have_button('Filtern')
  end

  it 'requests a stream update from every filter link' do
    rendered_component

    expect(page).to have_css('a[data-turbo-stream="true"]', minimum: 10, visible: :all)
    expect(page).not_to have_css('[data-testid="activity-filter-bar"] a:not([data-turbo-stream="true"])', visible: :all)
  end

  it 'groups object choices by what a person searches for' do
    rendered_component

    expect(page).to have_content('Tickets')
    expect(page).to have_content('Wissen')
    expect(page).to have_content('Zeiten')
    expect(page).to have_content('Verwaltung')
    expect(page).not_to have_content('Alle Objekte')
    expect(page).not_to have_content('Zeit-Session')
  end

  context 'with a knowledge area' do
    let(:current_filters) { { area: 'knowledge', action_type: 'status_changed' } }

    it 'offers knowledge actions and visibly drops an incompatible action from area links' do
      rendered_component

      action_labels = component.send(:action_options).map { |option| option[:label] }
      expect(action_labels).to include('Dokument erstellt', 'Notiz erstellt', 'Meeting erstellt')
      expect(action_labels).not_to include('Status geändert')

      tickets_url = component.send(:area_options).find { |option| option[:value] == 'tickets' }[:url]
      expect(tickets_url).to include('action_type=status_changed')
      knowledge_url = component.send(:area_options).find { |option| option[:value] == 'knowledge' }[:url]
      expect(knowledge_url).not_to include('action_type=')
    end
  end

  context 'with active filters' do
    let(:current_filters) { { area: 'tickets', actor_id: user.id, period: 'custom', date_from: '2026-09-01', date_to: '2026-09-10' } }

    it 'renders two-zone editable chips and one period chip for both bounds' do
      rendered_component

      expect(page).to have_content('Nur Änderungen')
      expect(page).to have_css('summary', text: 'Tickets')
      expect(page).to have_css('summary', text: 'Gabi Boyke')
      expect(page).to have_css('summary', text: '01.09.–10.09.2026')
      expect(page).to have_field('date_from', with: '2026-09-01', visible: :all)
      expect(page).to have_field('date_to', with: '2026-09-10', visible: :all)
      expect(page).to have_link('Zurücksetzen')
    end
  end
end
