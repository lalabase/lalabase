# frozen_string_literal: true

require 'rails_helper'

# R1 regression guard: the org tag list, its JSON autocomplete and the tag detail page
# must be scoped to the projects the current user can access. A user with access to only
# project A must not see tag names, counts or tagged items from project B. Org admins
# keep the full view.
RSpec.describe 'Organisations tags project scoping', type: :request do
  let(:organisation) { create(:organisation) }

  let(:standard_role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end
  let(:admin_role) { create(:admin_role, organisation: organisation) }

  let(:member) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: standard_role, active: true)
    end
    u
  end

  let(:admin) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: admin_role, active: true)
    end
    u
  end

  let(:project_a) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:project_b) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def grant(user, project, **areas)
    create(:project_permission, { user: user, project: project }.merge(areas))
  end

  def tag_on_ticket(project, name, title: 'a ticket')
    ActsAsTenant.with_tenant(organisation) do
      tag = create(:tag, name: name, organisation: organisation)
      ticket = create(:ticket, project: project, organisation: organisation, title: title)
      create(:tagging, tag: tag, taggable: ticket)
      tag
    end
  end

  # NOTE: on the HTML index: both the HTML and JSON branches share the same scoped
  # assignment `@tags = policy_scope(Tag)` (TagsController#index), so the JSON case below
  # proves the HTML index is scoped too. The full HTML render is not asserted here because
  # the index renders the shared `shared/_sortable_header` partial, whose
  # `url_for(request.path_parameters.merge(...))` is not exercised by any request spec in
  # this suite and is unrelated to this scoping fix.
  describe 'GET index (JSON autocomplete)' do
    it 'scopes the autocomplete payload to accessible projects' do
      grant(member, project_a, tickets_access: 'read_only')
      tag_on_ticket(project_a, 'visibletag')
      tag_on_ticket(project_b, 'hiddentag')
      sign_in member

      get organisation_tags_path(organisation, format: :json)

      names = JSON.parse(response.body).map { |t| t['name'] }
      expect(names).to include('visibletag')
      expect(names).not_to include('hiddentag')
    end
  end

  describe 'GET show' do
    it 'returns 404 (no-leak) for a tag the member cannot see' do
      grant(member, project_a, tickets_access: 'read_only')
      hidden = tag_on_ticket(project_b, 'hiddentag')
      sign_in member

      get organisation_tag_path(organisation, hidden)

      expect(response).to have_http_status(:not_found)
    end

    it 'shows a visible tag but only tagged items from accessible projects' do
      grant(member, project_a, tickets_access: 'read_only')
      tag = tag_on_ticket(project_a, 'sharedtag', title: 'OWN TICKET')
      ActsAsTenant.with_tenant(organisation) do
        foreign = create(:ticket, project: project_b, organisation: organisation, title: 'FOREIGN TICKET')
        create(:tagging, tag: tag, taggable: foreign)
      end
      sign_in member

      get organisation_tag_path(organisation, tag)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('OWN TICKET')
      expect(response.body).not_to include('FOREIGN TICKET')
    end

    it 'lets an admin see the tag with items from all projects' do
      tag = tag_on_ticket(project_a, 'sharedtag', title: 'OWN TICKET')
      ActsAsTenant.with_tenant(organisation) do
        foreign = create(:ticket, project: project_b, organisation: organisation, title: 'FOREIGN TICKET')
        create(:tagging, tag: tag, taggable: foreign)
      end
      sign_in admin

      get organisation_tag_path(organisation, tag)

      expect(response.body).to include('OWN TICKET')
      expect(response.body).to include('FOREIGN TICKET')
    end
  end
end
