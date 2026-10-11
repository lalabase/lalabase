# frozen_string_literal: true

require 'rails_helper'

# Every row on the Team page must offer a way to act on that person. The bug this
# guards: a role-based row had no remove button at all, so a member who fell back
# to their role after a removal could never be taken off the project again.
RSpec.describe Organisations::Team::MemberRowComponent, type: :component do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation) }

  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:plain_role) { create(:role, organisation: organisation, title: 'member') }
  let(:reader_role) do
    role = create(:role, organisation: organisation, title: 'tickets_reader')
    create(:project_read_permission, role: role, area: 'tickets')
    role
  end

  let(:manager) do
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    user
  end

  def member_in(role)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  def resolved(user, viewer: manager)
    AccessCheck::ProjectMemberAccessResolver
      .new(project: project, current_user: viewer)
      .for_user(user)
  end

  def render_row(user, viewer: manager, can_manage: true)
    with_request_url("/org/#{organisation.id}/projects/#{project.id}/project_permissions") do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(viewer)
      render_inline(described_class.new(member: resolved(user, viewer: viewer), project: project,
                                        organisation: organisation, can_manage: can_manage))
    end
  end

  def revoke_url(user)
    Rails.application.routes.url_helpers
         .revoke_organisation_project_project_permissions_path(organisation, project, user_id: user.id)
  end

  def label(key)
    I18n.t("views.organisations.project_permissions.member_row.#{key}")
  end

  describe 'a member with an explicit grant' do
    let(:user) { member_in(plain_role) }

    before { create(:project_permission, user: user, project: project, tickets_access: 'read_write') }

    it 'offers the remove button' do
      expect(render_row(user).to_html).to include(revoke_url(user))
    end

    it 'offers the inline edit' do
      expect(render_row(user).to_html).to include(label(:edit))
    end
  end

  describe 'a member who is on the project through a role right alone' do
    let(:user) { member_in(reader_role) }

    it 'offers the remove button directly, without the "make explicit" detour' do
      expect(render_row(user).to_html).to include(revoke_url(user))
    end

    it 'still offers "make explicit" for granting different rights' do
      expect(render_row(user).to_html).to include(label(:make_explicit))
    end
  end

  describe 'a blocked member' do
    let(:user) { member_in(reader_role) }

    before { create(:project_permission, user: user, project: project) }

    it 'is marked as blocked' do
      expect(render_row(user).to_html).to include(label(:blocked))
    end

    it 'names the role that is being overridden' do
      expect(render_row(user).to_html).to include('tickets_reader')
    end

    it 'offers to lift the block instead of removing again' do
      html = render_row(user).to_html

      expect(html).to include(label(:unblock))
      expect(html).not_to include(revoke_url(user))
    end

    it 'stays inline-editable so rights can be granted back' do
      expect(render_row(user).to_html).to include(label(:edit))
    end
  end

  describe 'an account admin' do
    let(:user) { member_in(admin_role) }

    it 'gets no remove button, because only the role can take them off' do
      html = render_row(user).to_html

      expect(html).not_to include(revoke_url(user))
      expect(html).not_to include(label(:unblock))
    end
  end

  describe 'your own row' do
    it 'offers no remove button' do
      create(:project_permission, user: manager, project: project, tickets_access: 'read_write')
      expect(render_row(manager).to_html).not_to include(revoke_url(manager))
    end
  end

  describe 'a viewer who may only read the team' do
    let(:user) { member_in(reader_role) }

    it 'sees no action buttons at all' do
      html = render_row(user, can_manage: false).to_html

      expect(html).not_to include(revoke_url(user))
      expect(html).not_to include(label(:make_explicit))
      expect(html).not_to include(label(:edit))
    end
  end
end
