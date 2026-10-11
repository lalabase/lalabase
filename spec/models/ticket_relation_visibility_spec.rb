# frozen_string_literal: true

require 'rails_helper'

# Who sees a relation (doc/ticket_relations_plan.md, revision 4, §4). Relations cross projects,
# so the other end may lie in a project the reader cannot see. The rule has one place,
# TicketRelation.visible_to: a relation is visible when BOTH ends are tickets the reader may
# read (TicketPolicy::Scope). A page only ever shows the relations of a ticket its reader reads,
# so that is "the other ticket is readable". A token narrows it to the projects it reaches.
RSpec.describe TicketRelation, :ci_guard, type: :model do
  let(:organisation) { create(:organisation) }
  let(:foreign_organisation) { create(:organisation) }
  let(:readable_project) { new_project(organisation) }
  let(:second_readable_project) { new_project(organisation) }
  let(:hidden_project) { new_project(organisation) }

  let(:reader) { member_reading(readable_project, second_readable_project) }
  let(:admin) { account_admin }

  let(:ticket) { new_ticket(readable_project, 'Shown ticket') }
  let(:readable_other) { new_ticket(readable_project, 'Readable, same project') }
  let(:readable_elsewhere) { new_ticket(second_readable_project, 'Readable, other project') }
  let(:hidden_other) { new_ticket(hidden_project, 'Hidden blocker') }

  let!(:same_project_relation) { link(ticket, readable_other, :blocks) }
  let!(:cross_project_relation) { link(readable_elsewhere, ticket, :relates_to) }
  let!(:hidden_relation) { link(hidden_other, ticket, :blocks) }
  # The hidden ticket at the TARGET end as well: a rule that checked one end only would pass
  # the case above and fail this one.
  let!(:hidden_target_relation) { link(ticket, new_ticket(hidden_project, 'Hidden follower'), :precedes) }

  after { ActsAsTenant.current_tenant = nil }

  # Setup only: each create loads its organisation for the belongs_to check, which Prosopite
  # would report from the second record on. What visible_to itself asks stays scanned.
  def new_project(org)
    Prosopite.pause { ActsAsTenant.with_tenant(org) { create(:project, organisation: org) } }
  end

  def new_ticket(project, title)
    Prosopite.pause { ActsAsTenant.with_tenant(project.organisation) { create(:ticket, project: project, title: title) } }
  end

  def link(source, target, type)
    Prosopite.pause do
      ActsAsTenant.with_tenant(source.organisation) do
        described_class.create!(source_ticket: source, target_ticket: target, relation_type: type)
      end
    end
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

  def visible_ids(user, token: nil)
    ActsAsTenant.with_tenant(organisation) { described_class.visible_to(user, organisation, token: token).pluck(:id) }
  end

  describe '.visible_to' do
    it 'shows a relation only when the reader may read both tickets, in or across projects' do
      expect(visible_ids(reader)).to contain_exactly(same_project_relation.id, cross_project_relation.id)
    end

    it 'hides the relation to a ticket in a project the reader cannot see' do
      expect(visible_ids(reader)).not_to include(hidden_relation.id, hidden_target_relation.id)
      # The relation exists: an account admin sees it, so the hiding is the rule, not a missing row.
      expect(visible_ids(admin)).to include(hidden_relation.id, hidden_target_relation.id)
    end

    it 'shows an account admin every relation of the organisation' do
      expect(visible_ids(admin)).to contain_exactly(same_project_relation.id, cross_project_relation.id,
                                                    hidden_relation.id, hidden_target_relation.id)
    end

    it 'shows nothing of another organisation, not even without a tenant set' do
      foreign_project = new_project(foreign_organisation)
      foreign = link(new_ticket(foreign_project, 'Foreign A'), new_ticket(foreign_project, 'Foreign B'), :blocks)

      ids = ActsAsTenant.without_tenant { described_class.visible_to(admin, organisation).pluck(:id) }

      expect(ids).to include(same_project_relation.id)
      expect(ids).not_to include(foreign.id)
    end

    it 'follows a revoked read right at once' do
      ActsAsTenant.with_tenant(organisation) do
        ProjectPermission.where(user: reader, project: second_readable_project).delete_all
      end

      expect(visible_ids(reader)).to contain_exactly(same_project_relation.id)
    end

    # Review 4 (plan §4): a person may see A and B while their token reaches A only. The API and
    # MCP (PR 5) pass the token; without this, a title from B would leave through a relation.
    context 'with a token' do
      it 'narrows an account admin to the projects the token reaches' do
        token = create(:personal_access_token, user: admin, organisations: [organisation],
                                               project_scopes: { organisation => [readable_project] })

        expect(visible_ids(admin, token: token)).to contain_exactly(same_project_relation.id)
      end

      it 'narrows nothing for a token that reaches every project' do
        token = create(:personal_access_token, user: admin, organisations: [organisation])

        expect(visible_ids(admin, token: token)).to contain_exactly(same_project_relation.id, cross_project_relation.id,
                                                                    hidden_relation.id, hidden_target_relation.id)
      end

      it 'shows nothing when the token does not reach the organisation' do
        token = create(:personal_access_token, user: admin, organisations: [foreign_organisation])

        expect(visible_ids(admin, token: token)).to be_empty
      end

      it 'never widens what the person may read' do
        token = create(:personal_access_token, user: reader, organisations: [organisation])

        expect(visible_ids(reader, token: token)).to contain_exactly(same_project_relation.id, cross_project_relation.id)
      end
    end
  end

  describe '.touching' do
    it 'finds the relations of a ticket from either end, and no others' do
      unrelated = link(readable_other, readable_elsewhere, :relates_to)

      ids = ActsAsTenant.with_tenant(organisation) { described_class.touching(ticket).pluck(:id) }

      expect(ids).to contain_exactly(same_project_relation.id, cross_project_relation.id, hidden_relation.id,
                                     hidden_target_relation.id)
      expect(ids).not_to include(unrelated.id)
    end
  end

  describe '#other_ticket_for and #kind_for' do
    # Every label of KINDS, read from both ends: the page of the source shows the stored label,
    # the page of the target the flipped one (relates_to reads the same from both).
    {
      blocks: %w[blocks blocked_by],
      precedes: %w[precedes follows],
      duplicates: %w[duplicates duplicated_by],
      relates_to: %w[relates_to relates_to]
    }.each do |type, (source_kind, target_kind)|
      it "reads #{type} as #{source_kind} from the source and #{target_kind} from the target" do
        relation = link(readable_other, readable_elsewhere, type)

        expect(relation.kind_for(readable_other)).to eq(source_kind)
        expect(relation.kind_for(readable_elsewhere)).to eq(target_kind)
        expect(relation.other_ticket_for(readable_other)).to eq(readable_elsewhere)
        expect(relation.other_ticket_for(readable_elsewhere)).to eq(readable_other)
      end
    end

    it 'covers every label a person can pick' do
      read = described_class.relation_types.keys.flat_map do |type|
        relation = link(new_ticket(readable_project, "S #{type}"), new_ticket(readable_project, "T #{type}"), type)
        [relation.kind_for(relation.source_ticket), relation.kind_for(relation.target_ticket)]
      end

      expect(read.uniq).to match_array(described_class::KINDS.keys)
    end
  end
end
