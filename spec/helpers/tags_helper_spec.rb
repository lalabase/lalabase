# frozen_string_literal: true

require 'rails_helper'

# R1 regression guard: accessible_tag_names feeds the tag-input autocomplete embedded in
# every ticket/note/document form. It must only return tag names from projects the current
# user can access — never the full org tag vocabulary.
RSpec.describe TagsHelper, type: :helper do
  let(:organisation) { create(:organisation) }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  let(:project_a) { create(:project, organisation: organisation) }
  let(:project_b) { create(:project, organisation: organisation) }

  def member_with(role)
    u = create(:user)
    create(:membership, user: u, organisation: organisation, role: role, active: true)
    u
  end

  def tag_on_ticket(project, name)
    tag = create(:tag, name: name, organisation: organisation)
    create(:tagging, tag: tag, taggable: create(:ticket, project: project, organisation: organisation))
    tag
  end

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  it 'returns only tag names used in projects the member can access' do
    member = member_with(standard_role)
    create(:project_permission, user: member, project: project_a, tickets_access: 'read_only')
    tag_on_ticket(project_a, 'visibletag')
    tag_on_ticket(project_b, 'hiddentag')
    allow(helper).to receive(:current_user).and_return(member)

    names = helper.accessible_tag_names

    expect(names).to include('visibletag')
    expect(names).not_to include('hiddentag')
  end

  it 'returns all org tag names for an admin' do
    admin = member_with(admin_role)
    tag_on_ticket(project_a, 'atag')
    tag_on_ticket(project_b, 'btag')
    allow(helper).to receive(:current_user).and_return(admin)

    names = helper.accessible_tag_names

    expect(names).to include('atag', 'btag')
  end
end
