# frozen_string_literal: true

require 'rails_helper'

# R4 regression guard: the filter-builder reference option lists must be scoped to the
# current user's accessible projects. User references (assignee) must not leak names/emails
# of foreign-project (or foreign-org) users. (Tag autocomplete in the filter builder is
# served by tags#index.json, scoped in R1 — the helper's tag branch is unreachable here
# because the 'tag' field is value_type :text, not :reference.)
RSpec.describe SmartFolderHelper, type: :helper do
  let(:organisation) { create(:organisation) }
  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end

  def member_in(role = standard_role)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  let(:project_a) { create(:project, organisation: organisation) }
  let(:project_b) { create(:project, organisation: organisation) }
  let(:me) { member_in }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:project_permission, user: me, project: project_a, tickets_access: 'read_only')
    allow(helper).to receive(:current_user).and_return(me)
  end

  after { ActsAsTenant.current_tenant = nil }

  describe 'assignee (User reference)' do
    it 'excludes users whose only project is inaccessible to the current user' do
      colleague = member_in
      foreigner = member_in
      create(:project_permission, user: colleague, project: project_a, tickets_access: 'read_only')
      create(:project_permission, user: foreigner, project: project_b, tickets_access: 'read_only')

      options = helper.available_reference_options(
        'assignee', organisation, project: project_a, accessible_project_ids: [project_a.id]
      )
      ids = options.map { |o| o[:value] }

      expect(ids).to include(colleague.id)
      expect(ids).not_to include(foreigner.id)
    end

    it 'includes the current user and project colleagues, scoped to the passed projects' do
      colleague = member_in
      create(:project_permission, user: colleague, project: project_a, tickets_access: 'read_only')

      options = helper.available_reference_options(
        'assignee', organisation, project: project_a, accessible_project_ids: [project_a.id]
      )
      ids = options.map { |o| o[:value] }

      expect(ids).to include(me.id, colleague.id)
    end
  end
  %w[creator assignee].each do |field|
    it "scopes #{field} in the server-rendered editor even without explicit project IDs" do
      colleague = member_in
      create(:project_permission, user: colleague, project: project_a, tickets_access: 'read_only')
      foreign_org = create(:organisation)
      foreigner = create(:user, first_name: 'ForeignIdentity')
      ActsAsTenant.with_tenant(foreign_org) do
        create(:membership, user: foreigner, organisation: foreign_org,
                            role: create(:role, organisation: foreign_org), active: true)
      end
      options = helper.available_reference_options(field, organisation, project: project_a)
      expect(options.map { |option| option[:value] }).to include(me.id, colleague.id)
      expect(options.map { |option| option[:value] }).not_to include(foreigner.id)
      expect(options.map { |option| option[:label] }.join).not_to include('ForeignIdentity')
    end
  end
end
