# frozen_string_literal: true

require 'rails_helper'

# What: the column picker saves the pins in the SAME request as the column list
#   (designer, 07.09.2026). Two endpoints answer it, because a list can live in
#   two places: the reader's base view and a saved view of its own.
# Type: request spec over both endpoints.
# Why: pins and columns belong to one view, so they are written in one breath -
#   two requests would be two chances to leave a view half saved. And a request
#   WITHOUT the param must leave the pins alone: an older tab still sends only
#   cols[], and it must not clear what somebody set in the meantime.
RSpec.describe 'Column pins', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { ActsAsTenant.with_tenant(organisation) { create(:user) } }
  let(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    end
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let!(:view_configuration) do
    ActsAsTenant.with_tenant(organisation) do
      ViewConfiguration.create!(user: user, project: project, view_type: 'tickets',
                                table_columns: %w[number title assignees created_at])
    end
  end

  before do
    ActsAsTenant.current_tenant = organisation
    membership
    sign_in user
  end

  describe 'the base view' do
    let(:url) { columns_organisation_project_view_configuration_path(organisation, project) }

    it 'writes the list and the pins in one request' do
      patch url, params: { cols: %w[number title assignees created_at], pins: %w[assignees] }

      expect(response).to have_http_status(:ok)
      expect(view_configuration.reload.pinned_column_keys).to eq(%w[assignees])
    end

    # ⚠️ Without the param the pins stay: an older tab sends cols[] alone, and
    # clearing on its behalf would silently undo a setting it never saw.
    it 'leaves the pins alone when a request carries none' do
      view_configuration.update!(pinned_column_keys: %w[created_at])

      patch url, params: { cols: %w[number title assignees created_at] }

      expect(view_configuration.reload.pinned_column_keys).to eq(%w[created_at])
    end

    it 'drops a pin on a column the reader may not see' do
      patch url, params: { cols: %w[number title assignees], pins: %w[assignees gibtesnicht] }

      expect(view_configuration.reload.pinned_column_keys).to eq(%w[assignees])
    end
  end

  describe 'a saved view of its own' do
    let(:folder) do
      create(:smart_folder, user: user, organisation: organisation, project: project,
                            target_object_type: 'Ticket',
                            display_columns: { 'table_columns' => %w[number title assignees] })
    end

    it 'writes the list and the pins into the folder' do
      patch columns_organisation_smart_folder_path(organisation, folder),
            params: { project_id: project.id, cols: %w[number title assignees], pins: %w[assignees] }

      expect(response).to have_http_status(:ok)
      expect(folder.reload.pinned_column_keys).to eq(%w[assignees])
      expect(folder.display_columns['table_columns']).to eq(%w[number title assignees])
    end
  end
end
