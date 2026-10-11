# frozen_string_literal: true

# spec/services/actors/sort_ticket_attribute_definitions_spec.rb
#
# What: unit spec for the SortTicketAttributeDefinitions actor (drag&drop reorder of
#   a project's ticket attribute definitions).
# Why: pins that position is persisted by list index and that a foreign id (another
#   project's definition) is silently ignored — the project scoping is the safety.

require 'rails_helper'

RSpec.describe Actors::SortTicketAttributeDefinitions, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  let!(:attr_a) { create(:ticket_attribute_definition, project: project, name: 'aaa', position: 0) }
  let!(:attr_b) { create(:ticket_attribute_definition, project: project, name: 'bbb', position: 1) }
  let!(:attr_c) { create(:ticket_attribute_definition, project: project, name: 'ccc', position: 2) }

  def sort(ids)
    described_class.call(project: project, ordered_ids: ids, current_user: user)
  end

  it 'returns a successful Result' do
    expect(sort([attr_a.id, attr_b.id, attr_c.id])).to be_success
  end

  it 'persists the new order by list index' do
    sort([attr_c.id, attr_a.id, attr_b.id])
    expect(attr_c.reload.position).to eq(0)
    expect(attr_a.reload.position).to eq(1)
    expect(attr_b.reload.position).to eq(2)
  end

  it 'ignores a foreign id (scoped to the project)' do
    other_project = create(:project, organisation: organisation)
    other_attr = create(:ticket_attribute_definition, project: other_project, position: 5)

    sort([other_attr.id, attr_a.id])

    expect(other_attr.reload.position).to eq(5) # untouched — not in this project
    expect(attr_a.reload.position).to eq(1)     # index 1 in the submitted order
  end

  it 'has a nil record (bulk reorder, no single primary record)' do
    actor = described_class.new(project: project, ordered_ids: [], current_user: user)
    expect(actor.record).to be_nil
  end
end
