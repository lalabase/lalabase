# frozen_string_literal: true

require 'rails_helper'

# Regression guard: the "Gespräche" (meetings) area must be a first-class item in
# the REAL project sidebar — NeoSidebarProjectItemComponent, the navigation users
# actually see on desktop AND inside the mobile hamburger drawer (rendered via
# common/_sidebar_project_list, id="sidebar-project-list").
#
# Meetings (Slice 1a, #219) was wired into the style-guide-only tab bar
# (NeoProjectNavigationComponent) and the orphaned common/_project_menu partial,
# but never into the live sidebar — so users who navigate via the sidebar could
# not reach the area at all.
#
# Coverage is behaviour-first, not line-first:
#   * gated presence — shown for EACH allowed access level (read_only, read_write),
#     hidden entirely without access. The negative case is body-wide (defense in
#     depth): it fails if the link ever leaks anywhere, e.g. a revived tab bar.
#   * link as one unit — path, bi-chat-quote icon (D8) and the navigation.meetings
#     label are asserted on the SAME anchor, so a copy-pasted path/icon/label drifts red.
#   * active state — on a meetings page the item carries the active marker, proving
#     SidebarHelper#current_sidebar_tab maps the meetings controller.
#   * per-project isolation — the link follows the project the member has :meetings
#     access on, not the member globally.
RSpec.describe 'Project sidebar: meetings link', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
  end

  let(:meetings_path) { organisation_project_meetings_path(organisation, project) }

  # A signed-up, active member of `organisation` with NO project access yet.
  def signed_up_member
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    user
  end

  # Grants per-area access on one project (e.g. meetings_access: 'read_only').
  # Tenant is set BEFORE the record is built — the factory-tenant trap.
  def grant(user, on:, **access)
    ActsAsTenant.with_tenant(organisation) do
      create(:project_permission, user: user, project: on, **access)
    end
  end

  # Shorthand for the common single-project case.
  def member_with(**access)
    user = signed_up_member
    grant(user, on: project, **access)
    user
  end

  # The sidebar subtree only — keeps presence assertions honest about WHERE the
  # link is, instead of matching a stray URL elsewhere on the page.
  def sidebar_of(response)
    Nokogiri::HTML(response.body).at_css('#sidebar-project-list')
  end

  describe 'presence, gated by :meetings area access' do
    # Positive iteration over the whole allow-list: dropping either level from the
    # gate (or from the enum mapping) makes one of these fail.
    %w[read_only read_write].each do |level|
      it "renders the sidebar meetings link for a member with #{level} meetings access" do
        sign_in member_with(tickets_access: 'read_only', meetings_access: level)

        get organisation_project_tickets_path(organisation, project)

        expect(response).to have_http_status(:ok)
        expect(sidebar_of(response).to_s).to include(meetings_path)
      end
    end

    it 'omits the meetings link everywhere for a member WITHOUT meetings access' do
      sign_in member_with(tickets_access: 'read_only')

      get organisation_project_tickets_path(organisation, project)

      expect(response).to have_http_status(:ok)
      # Body-wide, not sidebar-scoped: guards against any leak (e.g. a re-enabled tab bar).
      expect(response.body).not_to include(meetings_path)
    end
  end

  describe 'the sidebar link is one coherent unit (path + icon + label)' do
    it 'wires meetings_path, the bi-chat-quote icon (D8) and the navigation.meetings label onto one anchor' do
      sign_in member_with(meetings_access: 'read_only')

      get meetings_path

      link = sidebar_of(response).at_css(%(a[href="#{meetings_path}"]))
      expect(link).to be_present
      expect(link.at_css('i.bi-chat-quote')).to be_present               # design-review D8 glyph
      expect(link.text).to include(I18n.t('navigation.meetings'))        # correct i18n key, locale-agnostic
    end
  end

  describe 'active state on the meetings page' do
    it 'marks the sidebar meetings item active' do
      sign_in member_with(meetings_access: 'read_only')

      get meetings_path

      expect(response).to have_http_status(:ok)
      link = sidebar_of(response).at_css(%(a[href="#{meetings_path}"]))
      expect(link).to be_present
      # The one marker of an active sidebar row (SidebarNavHelper). It used to be
      # the ink bar on the left; that went when the shell got darker and the
      # state became a raised tile instead of a tint.
      expect(link['class']).to include('sidebar-row--active')
    end
  end

  describe 'per-project isolation' do
    it 'shows the link only for the project the member has :meetings access on' do
      other = ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      user = signed_up_member
      grant(user, on: project, meetings_access: 'read_only') # meetings here
      grant(user, on: other,   tickets_access: 'read_only')  # only tickets there
      sign_in user

      # Load the OTHER project so it is the current one; the sidebar still renders
      # both projects (each accessible), so we can compare their child links.
      get organisation_project_tickets_path(organisation, other)

      body = sidebar_of(response).to_s
      expect(body).to include(organisation_project_meetings_path(organisation, project))
      expect(body).not_to include(organisation_project_meetings_path(organisation, other))
    end
  end
end
