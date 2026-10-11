# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Organisations::SidebarPins', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }

  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
    sign_in user
  end

  def patch_pin(params)
    patch organisation_sidebar_pins_path(organisation_id: organisation.id),
          params: params,
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
  end

  describe 'PATCH /organisations/:organisation_id/sidebar_pins' do
    it 'toggles a project pin on and off' do
      patch_pin(project_id: project.id)
      expect(response).to have_http_status(:ok)
      expect(user.reload.sidebar_pins.project_pinned?(organisation, project.id)).to be true

      patch_pin(project_id: project.id)
      expect(user.reload.sidebar_pins.project_pinned?(organisation, project.id)).to be false
    end

    it 'toggles a section pin and implicitly pins the project' do
      patch_pin(project_id: project.id, section: 'tickets')

      expect(user.reload.sidebar_pins.pinned_sections_for(organisation, project.id)).to eq(['tickets'])
      expect(user.sidebar_pins.project_pinned?(organisation, project.id)).to be true
    end

    it 'toggles a pinned section off again while keeping the project pinned' do
      patch_pin(project_id: project.id, section: 'tickets')
      patch_pin(project_id: project.id, section: 'tickets')

      expect(user.reload.sidebar_pins.pinned_sections_for(organisation, project.id)).to eq([])
      expect(user.sidebar_pins.project_pinned?(organisation, project.id)).to be true
    end

    it 'toggles the meetings (Gespräche) section pin like any other whitelisted section' do
      patch_pin(project_id: project.id, section: 'meetings')

      expect(user.reload.sidebar_pins.pinned_sections_for(organisation, project.id)).to eq(['meetings'])
      expect(user.sidebar_pins.project_pinned?(organisation, project.id)).to be true
    end

    it 'treats a blank section param as a project toggle (presence guard)' do
      patch_pin(project_id: project.id, section: '')

      expect(user.reload.sidebar_pins.project_pinned?(organisation, project.id)).to be true
      expect(user.sidebar_pins.pinned_sections_for(organisation, project.id)).to eq([])
    end

    it 'does not persist a non-whitelisted section but still responds with the list' do
      patch_pin(project_id: project.id, section: 'settings')

      expect(response).to have_http_status(:ok)
      expect(user.reload.sidebar_pins.pins_for(organisation)).to eq({ 'projects' => [], 'sections' => {} })
    end

    it 'renders a turbo_stream replacing the sidebar project list' do
      patch_pin(project_id: project.id)

      expect(response.media_type).to eq('text/vnd.turbo-stream.html')
      expect(response.body).to include('sidebar-project-list')
    end

    # Whole-chain probe: the pin written to JSONB must come back out through
    # pins_for -> view handoff (pinned_sections_map[project.id.to_s]) ->
    # component pin_toggle labels in the SAME response. Dies when any link of
    # the chain (store key, org slot, string keys, component param) breaks.
    it 'renders the persisted pin state back into the turbo_stream response' do
      patch_pin(project_id: project.id, section: 'tickets')

      expect(response.body).to include(I18n.t('navigation.unpin_section', locale: :de))
      expect(response.body).to include(I18n.t('navigation.unpin_project', locale: :de))
    end

    it 'redirects to the organisation root for plain HTML requests' do
      patch organisation_sidebar_pins_path(organisation_id: organisation.id),
            params: { project_id: project.id }

      expect(response).to redirect_to(organisation_root_path(organisation_id: organisation.id))
      expect(user.reload.sidebar_pins.project_pinned?(organisation, project.id)).to be true
    end

    it 'returns not_found for a member without access to the project (policy guard)' do
      viewer = create(:user)
      ActsAsTenant.with_tenant(organisation) do
        plain_role = create(:role, organisation: organisation)
        create(:membership, user: viewer, organisation: organisation, role: plain_role, active: true)
      end
      sign_in viewer

      patch_pin(project_id: project.id)

      expect(response).to have_http_status(:not_found)
      expect(viewer.reload.sidebar_pins.project_pinned?(organisation, project.id)).to be false
    end

    it 'rejects pinning a project from another organisation' do
      other_org = create(:organisation)
      other_project = ActsAsTenant.with_tenant(other_org) do
        create(:project, organisation: other_org)
      end

      patch_pin(project_id: other_project.id)

      expect(response).to have_http_status(:not_found)
      expect(user.reload.sidebar_pins.project_pinned?(organisation, other_project.id)).to be false
    end

    it 'returns not_found for an unknown project id' do
      patch_pin(project_id: SecureRandom.uuid)

      expect(response).to have_http_status(:not_found)
    end
  end
end
