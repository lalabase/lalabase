# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::ListNotifications, the token-scoped inbox tool of the MCP
#       surface (inbox workflow S1).
# Type: Service spec.
# Why:  The first tool without a project gate. Three things must hold: (1) it runs
#       only with a token reach and marks its own authorization decision, so the
#       D7 tripwire stays armed; (2) the optional project_id filter cannot leak
#       existence (outside the reach reads like missing) nor reach the database
#       malformed; (3) a ticket row carries the exact address get_ticket takes
#       next, which is what turns the table into a workflow.
RSpec.describe Lalabase::Tools::ListNotifications do
  let(:user) { create(:user) }
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:ticket) do
    ActsAsTenant.with_tenant(organisation) do
      create(:ticket, project: project, organisation: organisation, creator: user)
    end
  end
  let(:token) { create(:personal_access_token, user: user, organisations: [organisation]) }
  let(:recorder) { Lalabase::Tools::AuthorizationRecorder.new }
  let(:context) { Lalabase::Tools::Context.new(actor: user, reach: token.reach, authorization: recorder) }

  before { make_token_owner_a_member(user, organisation, projects: [project]) }

  let!(:mine) do
    ActsAsTenant.with_tenant(organisation) do
      create(:notification, :ticket_commented, recipient: user, organisation: organisation,
                                               notifiable: ticket, project: project, state: 'queued')
    end
  end
  let!(:foreign) do
    ActsAsTenant.with_tenant(other_organisation) do
      create(:notification, recipient: user, organisation: other_organisation, state: 'queued')
    end
  end

  def run(args = {})
    described_class.execute(args: args, context: context)
  end

  def payload(args = {})
    JSON.parse(run(args).content)
  end

  describe 'contract metadata' do
    it 'is a token-scoped read tool that requires the actor and marks its own authorization' do
      expect(described_class.scope_mode).to eq(:token)
      expect(described_class.mutating?).to be false
      expect(described_class.requires_actor?).to be true
      expect(described_class.authorization_mode).to eq(:record)
    end
  end

  it 'refuses a context without a token reach' do
    project_context = Lalabase::Tools::Context.new(actor: user, organisation: organisation, project: project)
    result = described_class.execute(args: {}, context: project_context)
    expect(result.success?).to be false
    expect(result.error).to match(/token context/)
  end

  it 'lists the inbox within the token reach and marks the authorization decision (D7)' do
    expect(payload['data'].map { |r| r['id'] }).to eq([mine.id])
    expect(recorder.authorized?).to be true
  end

  it 'carries the address get_ticket takes next on a ticket row' do
    row = payload['data'].first
    expect(row['ticket']).to eq('id' => ticket.id, 'number' => ticket.number, 'title' => ticket.title,
                                'project_id' => project.id)
    expect(row['project']).to eq('id' => project.id, 'name' => project.name)
    expect(row['message']).to be_a(String)
  end

  it 'answers the pinned meta' do
    expect(payload['meta']).to eq('page' => 1, 'per_page' => 25, 'total' => 1, 'unread_total' => 1, 'since' => nil,
                                  'by_organisation' => [{ 'id' => organisation.id, 'name' => organisation.name,
                                                          'unread' => 1 }])
  end

  # One row in reach makes the project filter and the paging invisible: an
  # unfiltered call answers the same. Two projects and three rows separate them.
  describe 'narrowing and paging with a second project in reach' do
    let(:second_project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
    let(:second_ticket) do
      ActsAsTenant.with_tenant(organisation) do
        create(:ticket, project: second_project, organisation: organisation, creator: user)
      end
    end
    let!(:in_second) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, notifiable: second_ticket,
                              project: second_project, state: 'queued', created_at: 2.minutes.ago)
      end
    end
    let!(:read_in_second) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: user, organisation: organisation, notifiable: second_ticket,
                              project: second_project, state: 'read', read_at: 1.minute.ago, created_at: 1.minute.ago)
      end
    end

    # Several calls per example, the same query with other arguments; not a per-record N+1.
    before do
      make_token_owner_a_member(user, organisation, projects: [second_project])
      Prosopite.pause
    end

    it 'narrows to the named project' do
      expect(payload(project_id: second_project.id)['data'].map { |r| r['id'] }).to eq([in_second.id])
      expect(payload(project_id: project.id)['data'].map { |r| r['id'] }).to eq([mine.id])
    end

    it 'hands page, per_page and since through and reports total and unread_total of the query' do
      first = payload(status: 'all', per_page: 2, page: 1, since: '2026-01-01')
      expect(first['data'].map { |r| r['id'] }).to eq([read_in_second.id, in_second.id])
      expect(first['meta']).to include('page' => 1, 'per_page' => 2, 'total' => 3, 'unread_total' => 2,
                                       'since' => Time.zone.parse('2026-01-01').iso8601)
      second = payload(status: 'all', per_page: 2, page: 2)
      expect(second['data'].map { |r| r['id'] }).to eq([mine.id])
      expect(second['meta']).to include('page' => 2, 'since' => nil)
    end
  end

  it 'reports a project outside the reach exactly like a missing one' do
    outside = ActsAsTenant.with_tenant(other_organisation) { create(:project, organisation: other_organisation) }
    expect(run(project_id: outside.id).error).to eq(described_class::NOT_REACHABLE)
    expect(run(project_id: SecureRandom.uuid).error).to eq(described_class::NOT_REACHABLE)
  end

  # The sharper cell: the project EXISTS in the token's own organisation, only
  # the link is missing. A gate that checked the organisation alone would answer
  # an empty list here and thereby confirm the project exists.
  context 'with a token restricted to one project of its organisation' do
    let(:token) do
      create(:personal_access_token, user: user, organisations: [organisation],
                                     project_scopes: { organisation => [project] })
    end
    let(:unlinked) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

    it 'reports an unlinked project of its own organisation exactly like a missing one, and still answers the linked one' do
      # Access granted on purpose: it proves the TOKEN link is what refuses here, not a
      # missing right. Without the grant the example would pass for the wrong reason.
      make_token_owner_a_member(user, organisation, projects: [unlinked])

      expect(run(project_id: unlinked.id).error).to eq(described_class::NOT_REACHABLE)
      expect(payload(project_id: project.id)['data'].map { |r| r['id'] }).to eq([mine.id])
    end
  end

  it 'rejects a malformed project_id without touching the database' do
    expect(run(project_id: '42').error).to match(/invalid project_id/)
  end

  it 'passes an unusable since or status back as a clean tool error' do
    expect(run(since: 'gestern').error).to match(/since/)
    expect(run(status: 'unseen').error).to match(/status/)
  end
end
