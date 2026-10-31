# frozen_string_literal: true

require 'rails_helper'

# Web paths for sub-tasks: parent_id is permitted, but the same-project / fixed-parent
# guards live in the model. These specs prove a valid parent attaches the child, that a
# tampered parent_id (cross-project, cross-tenant) is rejected (no child is created), and
# that an update cannot change the parent of a saved ticket (no cycle can be built).
RSpec.describe 'Tickets sub-tasks (create)', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:parent) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, creator: user)
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  def children_of(parent_ticket)
    ActsAsTenant.with_tenant(organisation) { Ticket.where(parent_id: parent_ticket.id).to_a }
  end

  it 'creates a child ticket when parent_id is valid (same project)' do
    expect do
      post organisation_project_tickets_path(organisation, project),
           params: { ticket: { title: 'Texte liefern', parent_id: parent.id } }
    end.to change { children_of(parent).size }.by(1)

    child = children_of(parent).last
    expect(child.title).to eq('Texte liefern')
    expect(child.project_id).to eq(project.id)
  end

  it 'rejects a cross-project parent_id (no child created)' do
    other_project = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    foreign_parent = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: other_project, creator: user) }

    expect do
      post organisation_project_tickets_path(organisation, project),
           params: { ticket: { title: 'Getampert', parent_id: foreign_parent.id } }
    end.not_to(change { ActsAsTenant.with_tenant(organisation) { Ticket.count } })

    expect(children_of(foreign_parent)).to be_empty
  end

  it 'rejects a cross-tenant parent_id (no child created)' do
    other_org = create(:organisation)
    foreign_parent = ActsAsTenant.with_tenant(other_org) do
      create(:ticket, project: create(:project, organisation: other_org))
    end

    expect do
      post organisation_project_tickets_path(organisation, project),
           params: { ticket: { title: 'Cross-Tenant', parent_id: foreign_parent.id } }
    end.not_to(change { ActsAsTenant.with_tenant(organisation) { Ticket.where(project: project).count } })
  end

  describe 'PATCH with a changed parent_id' do
    let(:cannot_change) { I18n.t('activerecord.errors.models.ticket.attributes.parent_id.cannot_change') }

    def parent_id_of(ticket)
      ActsAsTenant.with_tenant(organisation) { ticket.reload.parent_id }
    end

    it 'leaves the parent of a top-level ticket unchanged and answers with the refusal' do
      ticket = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user) }

      patch organisation_project_ticket_path(organisation, project, ticket),
            params: { ticket: { title: ticket.title, parent_id: parent.id } }

      expect(response).to have_http_status(:found)
      expect(flash[:notice]).to be_nil
      expect(flash[:alert]).to include(cannot_change)
      # The whole sentence a German reader sees: field name and message, both German.
      expect(flash[:alert]).to include('Übergeordnete Aufgabe kann nach dem Anlegen nicht mehr geändert werden')
      expect(parent_id_of(ticket)).to be_nil
    end

    it 'cannot close a cycle by giving a parent its own child as parent' do
      child = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user, parent: parent) }

      patch organisation_project_ticket_path(organisation, project, parent),
            params: { ticket: { title: parent.title, parent_id: child.id } }

      expect(response).to have_http_status(:found)
      expect(flash[:notice]).to be_nil
      expect(flash[:alert]).to include(cannot_change)
      expect(parent_id_of(parent)).to be_nil
      expect(parent_id_of(child)).to eq(parent.id)
    end

    it 'does not detach a child through an empty parent_id' do
      child = ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project, creator: user, parent: parent) }

      patch organisation_project_ticket_path(organisation, project, child),
            params: { ticket: { title: child.title, parent_id: '' } }

      expect(flash[:notice]).to be_nil
      expect(parent_id_of(child)).to eq(parent.id)
    end
  end
end
