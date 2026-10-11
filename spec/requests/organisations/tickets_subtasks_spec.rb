# frozen_string_literal: true

require 'rails_helper'

# Web create path for sub-tasks: parent_id is permitted, but the same-project / one-level
# guards live in the model. These specs prove a valid parent attaches the child and that a
# tampered parent_id (cross-project, cross-tenant) is rejected — no child is created.
RSpec.describe 'Tickets sub-tasks (create)', type: :request do
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
end
