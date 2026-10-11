# frozen_string_literal: true

require 'rails_helper'

# What: The slimmed-down sidebar footer (utility row + account) and the relocated
#       "Neues Projekt" entry at the end of the sidebar project list.
# Type: Request spec — the sidebar renders inside the app layout, so a GET against an
#       org page (and the org-free cockpit) exercises it end-to-end (auth, tenant,
#       layout cascade, permission gates).
# Why:  Pins the footer declutter DECISION POINTS so a regression breaks a test:
#         - help collapsed into an icon-only "?" (still reachable via title/aria-label,
#           still org-INDEPENDENT: present on the cockpit too);
#         - "Neues Projekt" lives in the project list, NOT in the footer anymore,
#           and stays behind the ProjectPolicy#create? gate; since the label row
#           (mock 04.09.) it is the icon-only + next to the PROJEKTE caption;
#         - with zero projects a first-run CTA renders IN ADDITION — the sidebar
#           is the only entry point for the very first project, and a bare +
#           alone would be an easily missed dead end.
RSpec.describe 'Sidebar footer navigation', type: :request do
  let(:user) { create(:user) }
  let(:organisation) { create(:organisation) }

  def page_doc
    Capybara.string(response.body)
  end

  def help_link_css
    "a[href='#{help_path}'][title='#{I18n.t('navigation.help')}']"
  end

  def new_project_href
    new_organisation_project_path(organisation_id: organisation.id)
  end

  # Membership with either the admin role or a plain member role carrying the given
  # projects-category permissions. create_new_projects is the gate behind
  # ProjectPolicy#create?; a read_access_*_all_projects action makes the org's
  # projects visible in the sidebar list (otherwise the list renders empty).
  def join_org(admin: false, project_permissions: [])
    ActsAsTenant.with_tenant(organisation) do
      title = admin ? Role::ACCOUNT_ADMIN_TITLE : 'member'
      role = create(:role, organisation: organisation, title: title)
      project_permissions.each do |action|
        create(:permission, role: role, category: 'projects', action: action, allowed: true)
      end
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  describe 'member who may create projects, org with a project' do
    before do
      join_org(project_permissions: %w[create_new_projects read_access_notes_all_projects])
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      sign_in user
      get organisation_root_path(organisation)
    end

    it 'renders help as an icon-only link (title + aria-label carry the label)' do
      expect(response).to have_http_status(:ok)
      expect(page_doc).to have_css("#{help_link_css}[aria-label='#{I18n.t('navigation.help')}']")
      # Icon-only: the accessible name lives in the attributes, not in link text.
      expect(page_doc.find(help_link_css).text.strip).to eq('')
    end

    it 'offers "Neues Projekt" exactly once — the + behind the PROJEKTE label' do
      expect(page_doc).to have_css(
        "#sidebar-project-list a[href='#{new_project_href}'][title='#{I18n.t('navigation.new_project')}']" \
        "[aria-label='#{I18n.t('navigation.new_project')}']"
      )
      expect(page_doc).to have_css("a[href='#{new_project_href}']", count: 1)
      # Icon-only: the accessible name lives in the attributes, not in link text.
      expect(page_doc.find("a[href='#{new_project_href}']").text.strip).to eq('')
      # The section label above the list names it.
      expect(response.body).to include(I18n.t('navigation.projects_label'))
      # No first-run CTA while projects exist.
      expect(response.body).not_to include(I18n.t('navigation.no_projects_yet'))
    end
  end

  describe 'member without the create-projects permission' do
    before do
      join_org(project_permissions: %w[read_access_notes_all_projects])
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
      sign_in user
      get organisation_root_path(organisation)
    end

    it 'renders no "Neues Projekt" link at all' do
      expect(response).to have_http_status(:ok)
      expect(page_doc).to have_no_css("a[href='#{new_project_href}']")
      expect(response.body).not_to include(I18n.t('navigation.no_projects_yet'))
    end
  end

  describe 'admin in an org without any project' do
    before do
      join_org(admin: true)
      sign_in user
      get organisation_root_path(organisation)
    end

    it 'shows the first-run CTA in the project list' do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('navigation.no_projects_yet'))
      expect(page_doc).to have_css("#sidebar-project-list a[href='#{new_project_href}']",
                                   text: I18n.t('navigation.new_project'))
    end
  end

  describe 'org-free page (cockpit)' do
    before do
      join_org(admin: true)
      sign_in user
      get select_organisation_path
    end

    it 'keeps the icon-only help reachable without an organisation context' do
      expect(response).to have_http_status(:ok)
      expect(page_doc).to have_css(help_link_css)
    end
  end
end
