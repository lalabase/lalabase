# frozen_string_literal: true

require 'rails_helper'

# The endpoint behind the column picker's "für alle Ansichten übernehmen"
# (doc/spaltenwahl_plan.md, D5): the reader's exception. One list into the base
# view and into every ticket view of the reader's OWN in this project, and into
# nothing else: a view someone else owns, shared or public, is theirs.
RSpec.describe 'Organisations::ViewConfigurations#apply_columns_to_all', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:colleague) { create(:user) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:other_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  let(:own_project_view) { folder(name: 'Meine', owner: user, project: project) }
  let(:own_org_wide_view) { folder(name: 'Meine überall', owner: user, project: nil) }
  let(:own_elsewhere) { folder(name: 'Meine anderswo', owner: user, project: other_project) }
  let(:colleagues_public) { folder(name: 'Öffentlich', owner: colleague, project: project, is_public: true) }
  let(:shared_editable) do
    f = folder(name: 'Geteilt', owner: colleague, project: project)
    ActsAsTenant.with_tenant(organisation) { create(:smart_folder_share, smart_folder: f, user: user, can_edit: true) }
    f
  end

  def folder(name:, owner:, project:, is_public: false)
    ActsAsTenant.with_tenant(organisation) do
      create(:smart_folder, name: name, organisation: organisation, project: project, user: owner,
                            target_object_type: 'Ticket', is_public: is_public,
                            display_columns: { 'table_columns' => %w[number title assignees] })
    end
  end

  def columns_of(view)
    ActsAsTenant.with_tenant(organisation) { view.reload.ordered_columns }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    create(:membership, user: colleague, organisation: organisation, role: admin_role, active: true)
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  it 'writes the list into the base view and the own ticket views of this project, names the count, and leaves every other view alone' do
    [own_project_view, own_org_wide_view, own_elsewhere, colleagues_public, shared_editable]

    patch apply_columns_to_all_organisation_project_view_configuration_path(organisation, project),
          params: { view_configuration: { table_columns: %w[created_at nope tags] } }

    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(organisation_project_tickets_path(organisation, project))
    expect(flash[:notice]).to eq('Spalten für 3 Ansichten übernommen.')

    applied = %w[number title created_at tags]
    base = ActsAsTenant.with_tenant(organisation) { ViewConfiguration.for_user_project(user, project, 'tickets') }
    expect(base).to be_persisted
    expect(base.ordered_columns).to eq(applied)
    expect(columns_of(own_project_view)).to eq(applied)
    expect(columns_of(own_org_wide_view)).to eq(applied)

    untouched = %w[number title assignees]
    expect(columns_of(own_elsewhere)).to eq(untouched)
    expect(columns_of(colleagues_public)).to eq(untouched)
    expect(columns_of(shared_editable)).to eq(untouched)
  end

  it 'says "eine Ansicht" when only the base view took the list' do
    patch apply_columns_to_all_organisation_project_view_configuration_path(organisation, project),
          params: { view_configuration: { table_columns: %w[created_at] } }

    expect(flash[:notice]).to eq('Spalten für eine Ansicht übernommen.')
  end

  # A meeting view without a project belongs to "Alle Meetings" and shows only
  # there (meetings_uebersicht_vereinheitlichen_plan.md, decision 3). Until PR 2
  # the project page's "für alle Ansichten übernehmen" still wrote into it, so a
  # click on a project page changed the columns of a list it does not show.
  # Ticket views without a project keep showing in every project list and keep
  # taking the list (first example).
  describe 'meeting views' do
    def meeting_folder(name:, owner:, project:)
      ActsAsTenant.with_tenant(organisation) do
        create(:smart_folder, name: name, organisation: organisation, project: project, user: owner,
                              target_object_type: 'Meeting', display_columns: { 'table_columns' => %w[title occurred_at] })
      end
    end

    it 'writes the own meeting views of this project and none of the overview' do
      own_project_view = meeting_folder(name: 'Projekt', owner: user, project: project)
      own_overview_view = meeting_folder(name: 'Übersicht', owner: user, project: nil)
      own_elsewhere = meeting_folder(name: 'Anderswo', owner: user, project: other_project)

      patch apply_columns_to_all_organisation_project_view_configuration_path(organisation, project, view_type: 'meetings'),
            params: { view_configuration: { table_columns: %w[creator] } }

      expect(response).to redirect_to(organisation_project_meetings_path(organisation, project))
      expect(flash[:notice]).to eq('Spalten für 2 Ansichten übernommen.')
      expect(columns_of(own_project_view)).to eq(%w[title creator])
      expect(columns_of(own_overview_view)).to eq(%w[title occurred_at])
      expect(columns_of(own_elsewhere)).to eq(%w[title occurred_at])
    end
  end
end
