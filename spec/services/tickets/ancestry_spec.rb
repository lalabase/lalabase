# frozen_string_literal: true

require 'rails_helper'

# A ticket's ancestors, root first, read in one query. These examples pin the order, the
# single query, that a cycle written past the model cannot make the query run forever, and
# that the walk never leaves the ticket's own project.
RSpec.describe Tickets::Ancestry do
  let(:organisation) { create(:organisation) }
  let(:projects) do
    ActsAsTenant.with_tenant(organisation) { create_list(:project, 2, organisation: organisation) }
  end
  let(:root) { create(:ticket, project: projects[0]) }
  let(:level1) { create(:ticket, project: projects[0], parent: root) }
  let(:level2) { create(:ticket, project: projects[0], parent: level1) }
  let(:level3) { create(:ticket, project: projects[0], parent: level2) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # Past the model, as rows written before any rule existed would be.
  def raw_parent(ticket, parent)
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array(['UPDATE tickets SET parent_id = ? WHERE id = ?', parent.id, ticket.id])
    )
  end

  def ancestors_of(ticket)
    described_class.call(ticket: ticket)
  end

  it 'returns nothing for a ticket without parent' do
    expect(ancestors_of(root)).to eq([])
  end

  it 'returns the parent of a direct child' do
    expect(ancestors_of(level1).map(&:id)).to eq([root.id])
  end

  it 'returns every ancestor from the root down to the direct parent' do
    expect(ancestors_of(level3).map(&:id)).to eq([root.id, level1.id, level2.id])
  end

  it 'carries id, number and project_id of each ancestor' do
    ancestor = ancestors_of(level1).first

    expect([ancestor.id, ancestor.number, ancestor.project_id]).to eq([root.id, root.number, root.project_id])
  end

  it 'asks the database once for a ticket four levels deep' do
    ticket = level3

    statements = capture_sql { ancestors_of(ticket) }

    expect(statements.size).to eq(1)
  end

  it 'ends on a cycle already in the data and returns a finite list' do
    ticket_a = root
    ticket_b = create(:ticket, project: projects[0])
    raw_parent(ticket_a, ticket_b)
    raw_parent(ticket_b, ticket_a)
    ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = '2s'")

    expect(ancestors_of(ticket_a.reload).map(&:id)).to eq([ticket_b.id])
    expect(ancestors_of(ticket_b.reload).map(&:id)).to eq([ticket_a.id])
  end

  it 'ends on a ticket that is its own parent' do
    raw_parent(root, root)
    ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = '2s'")

    expect(ancestors_of(root.reload)).to eq([])
  end

  it 'does not return an ancestor in another project, nor anything above it' do
    foreign_root = create(:ticket, project: projects[1])
    foreign = create(:ticket, project: projects[1], parent: foreign_root)
    raw_parent(root, foreign)

    expect(ancestors_of(level2.reload).map(&:id)).to eq([root.id, level1.id])
  end

  it 'does not return an ancestor of another organisation, even one claiming the same project' do
    other_org = create(:organisation)
    foreign = ActsAsTenant.with_tenant(other_org) do
      create(:ticket, project: create(:project, organisation: other_org))
    end
    # Only the organisation clause can tell this row apart: its project_id matches.
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array(['UPDATE tickets SET project_id = ?, number = 9999 WHERE id = ?', root.project_id, foreign.id])
    )
    raw_parent(root, foreign)

    expect(ancestors_of(level1.reload).map(&:id)).to eq([root.id])
  end
end
