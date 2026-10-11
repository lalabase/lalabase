# frozen_string_literal: true

require 'rails_helper'

# MoveTicket writes via update_columns, which BYPASSES model validations — so the
# "sub-tasks stay in one project" invariant must be guarded explicitly in the actor.
# These specs prove the guard fires BEFORE the move (update_columns can't smuggle a
# child/parent across projects) and that normal tickets still move (no regression).
RSpec.describe Actors::MoveTicket, 'hierarchy guard', type: :service do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let(:source_project) { create(:project, organisation: organisation) }
  let(:target_project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, role: admin_role)
    Current.user = user
    create(:project_permission, user: user, project: source_project, tickets_access: 'read_write')
    create(:project_permission, user: user, project: target_project, tickets_access: 'read_write')
  end

  after { ActsAsTenant.current_tenant = nil }

  let(:parent) { create(:ticket, project: source_project, organisation: organisation, creator: user) }

  it 'blocks moving a ticket that has children and leaves the whole subtree in place' do
    child = create(:ticket, project: source_project, organisation: organisation, creator: user, parent: parent)

    result = described_class.new(ticket: parent, target_project: target_project, current_user: user).call

    expect(result.success?).to be(false)
    expect(result.code).to eq(:has_hierarchy)
    # Neither the parent nor the child moved: the guard fires BEFORE perform_move (update_columns).
    expect(parent.reload.project_id).to eq(source_project.id)
    expect(child.reload.project_id).to eq(source_project.id)
  end

  it 'blocks moving a child ticket (has a parent) and does not change its project' do
    child = create(:ticket, project: source_project, organisation: organisation, creator: user, parent: parent)

    result = described_class.new(ticket: child, target_project: target_project, current_user: user).call

    expect(result.success?).to be(false)
    expect(result.code).to eq(:has_hierarchy)
    expect(child.reload.project_id).to eq(source_project.id)
  end

  it 'still moves a normal ticket without parent or children (regression guard)' do
    plain = create(:ticket, project: source_project, organisation: organisation, creator: user)

    result = described_class.new(ticket: plain, target_project: target_project, current_user: user).call

    expect(result.success?).to be(true)
    expect(plain.reload.project_id).to eq(target_project.id)
  end
end
