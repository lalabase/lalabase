# frozen_string_literal: true

require 'rails_helper'

# What a token holder can FIND: the rows of one organisation, inside the policy scope, inside the
# token's reach. Missing, foreign, unreadable and out of reach must all look the same, so they run
# through one list of cases; the positive cases next to them keep the negatives from being green
# in a vacuum.
RSpec.describe Tickets::ReadableForToken, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:foreign_organisation) { create(:organisation) }
  let(:project_a) { new_project(organisation) }
  let(:project_b) { new_project(organisation) }
  let(:hidden_project) { new_project(organisation) }

  let(:reader) { member_reading(project_a, project_b) }
  let(:admin) { account_admin }

  let(:ticket_a) { new_ticket(project_a, 'In reach') }
  let(:ticket_b) { new_ticket(project_b, 'Readable, out of reach') }
  let(:hidden_ticket) { new_ticket(hidden_project, 'Unreadable') }
  let(:foreign_ticket) { new_ticket(new_project(foreign_organisation), 'Foreign') }
  let(:all_tickets) { [ticket_a, ticket_b, hidden_ticket] }

  after { ActsAsTenant.current_tenant = nil }

  # Setup only: each create loads its organisation for the belongs_to check, which Prosopite
  # would report from the second record on. What the service itself asks stays scanned.
  def new_project(org)
    Prosopite.pause { ActsAsTenant.with_tenant(org) { create(:project, organisation: org) } }
  end

  def new_ticket(project, title)
    Prosopite.pause { ActsAsTenant.with_tenant(project.organisation) { create(:ticket, project: project, title: title) } }
  end

  def member_reading(*projects)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      projects.each { |project| create(:project_permission, user: user, project: project, tickets_access: 'read_only') }
    end
    user
  end

  def account_admin
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:admin_role, organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  def token_for(user, **scopes)
    Prosopite.pause { create(:personal_access_token, user: user, **scopes) }
  end

  def token_reaching_a(user)
    token_for(user, organisations: [organisation], project_scopes: { organisation => [project_a] })
  end

  def token_reaching_everything(user)
    token_for(user, organisations: [organisation])
  end

  def found(user, id, token: nil, relation: Ticket, tenant: organisation)
    ActsAsTenant.with_tenant(tenant) do
      described_class.call(user: user, organisation: organisation, relation: relation, token: token).find_by(id: id)
    end
  end

  # One query for several rows: asking once per ticket would read as an N+1 to Prosopite.
  def found_tickets(user, tickets, token: nil)
    ActsAsTenant.with_tenant(organisation) do
      described_class.call(user: user, organisation: organisation, token: token).where(id: tickets.map(&:id)).to_a
    end
  end

  # A relation that carries no tenant condition of its own, so nothing but the service can keep a
  # foreign row out of it.
  def relation_without_tenant
    ActsAsTenant.without_tenant { Ticket.all }
  end

  describe 'what cannot be found' do
    # The reader reads A and B, the token reaches A and the hidden project: every row but A's is
    # hidden for one reason alone, so the policy scope and the reach each carry their own case.
    let(:token) { token_for(reader, organisations: [organisation], project_scopes: { organisation => [project_a, hidden_project] }) }

    {
      'a missing id' => -> { SecureRandom.uuid },
      'a ticket of a foreign organisation' => -> { foreign_ticket.id },
      'a ticket the user may not read' => -> { hidden_ticket.id },
      'a ticket the user may read and the token does not reach' => -> { ticket_b.id }
    }.each do |name, id|
      it "gives the same nil for #{name}" do
        expect(found(reader, instance_exec(&id), token: token)).to be_nil
      end

      it "gives the same nil for #{name} on a relation without a tenant" do
        expect(found(reader, instance_exec(&id), token: token, relation: relation_without_tenant)).to be_nil
      end
    end

    it 'finds the ticket in reach through the same call' do
      expect(found(reader, ticket_a.id, token: token)).to eq(ticket_a)
    end
  end

  describe 'with a token' do
    it 'narrows an account admin to the projects the token reaches' do
      token = token_reaching_a(admin)

      expect(found(admin, ticket_a.id, token: token)).to eq(ticket_a)
      expect(found(admin, ticket_b.id, token: token)).to be_nil
    end

    it 'narrows nothing for a token that reaches every project' do
      token = token_reaching_everything(admin)

      expect(found_tickets(admin, all_tickets, token: token)).to match_array(all_tickets)
    end

    it 'never widens what the person may read' do
      token = token_reaching_everything(reader)

      expect(found(reader, ticket_b.id, token: token)).to eq(ticket_b)
      expect(found(reader, hidden_ticket.id, token: token)).to be_nil
    end

    it 'finds nothing when the token does not reach the organisation, never everything' do
      token = token_for(admin, organisations: [foreign_organisation])

      expect(found_tickets(admin, all_tickets, token: token)).to be_empty
      expect(found(admin, ticket_a.id, token: token_reaching_everything(admin))).to eq(ticket_a)
    end
  end

  describe 'an empty reach' do
    {
      'a token outside the organisation' => -> { token_for(admin, organisations: [foreign_organisation]) },
      'a token of the organisation with an empty project list' => lambda {
        token_for(admin, organisations: [organisation], project_scopes: { organisation => [] })
      }
    }.each do |name, build_token|
      it "asks no rights for #{name} and finds nothing" do
        token = instance_exec(&build_token)
        tickets = all_tickets
        expect(Pundit).not_to receive(:policy_scope!)

        expect(found_tickets(admin, tickets, token: token)).to be_empty
      end
    end

    it 'does ask the rights for a token that reaches something' do
      token = token_reaching_a(admin)
      tickets = all_tickets
      expect(Pundit).to receive(:policy_scope!).once.and_call_original

      expect(found_tickets(admin, tickets, token: token)).to contain_exactly(ticket_a)
    end
  end

  describe 'without a token' do
    it 'gives a reader what the policy scope gives' do
      expect(found(reader, ticket_b.id)).to eq(ticket_b)
      expect(found(reader, hidden_ticket.id)).to be_nil
    end

    it 'gives an account admin every project' do
      expect(found_tickets(admin, all_tickets)).to match_array(all_tickets)
    end
  end

  # An account admin's policy scope is scope.all, so here the organisation binding stands alone.
  describe 'the organisation binding' do
    it 'keeps a foreign ticket out for an account admin, with and without a token' do
      expect(found(admin, ticket_a.id, relation: relation_without_tenant)).to eq(ticket_a)
      expect(found(admin, foreign_ticket.id, relation: relation_without_tenant)).to be_nil

      token = token_reaching_everything(admin)
      expect(found(admin, ticket_a.id, token: token, relation: relation_without_tenant)).to eq(ticket_a)
      expect(found(admin, foreign_ticket.id, token: token, relation: relation_without_tenant)).to be_nil
    end

    it 'gives the same rows whatever tenant is current when it is built and run' do
      ticket_a

      expect(found(admin, ticket_a.id, tenant: foreign_organisation)).to eq(ticket_a)
      expect(found(admin, ticket_a.id, tenant: nil)).to eq(ticket_a)
      expect(found(admin, foreign_ticket.id, tenant: foreign_organisation)).to be_nil
    end

    it 'never checks the rights in the current tenant instead of the organisation' do
      Prosopite.pause do
        ActsAsTenant.with_tenant(foreign_organisation) do
          role = create(:admin_role, organisation: foreign_organisation)
          create(:membership, user: reader, organisation: foreign_organisation, role: role, active: true)
        end
      end

      expect(found(reader, hidden_ticket.id, tenant: foreign_organisation)).to be_nil
      expect(found(reader, ticket_a.id, tenant: foreign_organisation)).to eq(ticket_a)
    end
  end

  describe 'a narrower relation' do
    it 'stays narrowed' do
      relation = ActsAsTenant.with_tenant(organisation) { project_a.tickets }

      expect(found(admin, ticket_a.id, relation: relation)).to eq(ticket_a)
      expect(found(admin, ticket_b.id, relation: relation)).to be_nil
    end
  end

  it 'answers with a relation, so the caller can narrow it further and nothing raises' do
    relation = ActsAsTenant.with_tenant(organisation) { described_class.call(user: reader, organisation: organisation) }

    expect(relation).to be_a(ActiveRecord::Relation)
    expect(ActsAsTenant.with_tenant(organisation) { relation.where(id: ticket_a.id).first }).to eq(ticket_a)
    expect(ActsAsTenant.with_tenant(organisation) { relation.where(id: SecureRandom.uuid).first }).to be_nil
  end
end
