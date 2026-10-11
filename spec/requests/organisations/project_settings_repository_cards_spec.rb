# frozen_string_literal: true

require 'rails_helper'

# The repository-backed feature cards on the project settings page: "chat with
# your code" (code index) and "show documentation" (doc sync). Two motivations,
# one mechanism — both CTAs lead to the same repository management page.
#
# The cards are purely visual — the repo page stays Pundit-protected — but they
# must obey the three-tier contract (manage / view-only / none) AND, critically,
# render for EVERY settings visitor, not just org admins. The settings page
# itself is reachable by a non-admin with change_project_properties; the cards
# must sit OUTSIDE the admin? block that wraps the ticket-fields card, or that
# whole audience silently loses them. That "conditional trap" gets its own guard
# here. The chat card is additionally org-gated: a chat-less org gets no dead
# promise, only the documentation card.
RSpec.describe 'Project settings — repository feature cards', type: :request do
  let(:organisation) { create(:organisation, code_indexing_enabled: true) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:edit_path) { edit_organisation_project_path(organisation, project) }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  # A NON-admin who can open the settings page: change_project_properties requires
  # a project-permission row AND the role permission. The area access on that row
  # is varied per persona to hit each tier.
  def settings_visitor(project_access:)
    role = create(:role, organisation: organisation, title: "Editor #{SecureRandom.hex(3)}")
    create(:permission, role: role, category: 'projects', action: 'change_project_properties', allowed: true)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      ProjectPermission.create!({ user: user, project: project }.merge(project_access))
    end
    user
  end

  let(:chat_card_title) { I18n.t('views.organisations.projects.edit.chat_with_code_title') }
  let(:docs_card_title) { I18n.t('views.organisations.projects.edit.documentation_title') }

  describe 'the conditional-trap guard: cards are OUTSIDE the admin? block' do
    # documentation:write on the project → also grants repo management, so this
    # non-admin lands in the MANAGE tier. If the cards were nested in the admin?
    # block, this user would see nothing — hence this is the structural guard.
    let(:non_admin_manager) { settings_visitor(project_access: { documentation_access: 'read_write' }) }

    before { sign_in non_admin_manager }

    it 'renders both cards for a non-admin settings visitor' do
      get edit_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(chat_card_title)
      expect(response.body).to include(docs_card_title)
    end

    it 'offers the manage/connect action to that non-admin (manage tier)' do
      get edit_path
      expect(response.body).to include(I18n.t('views.organisations.projects.edit.connect_repository'))
    end
  end

  describe 'manage tier (org admin)' do
    let(:admin_role) { create(:admin_role, organisation: organisation) }
    let(:admin) do
      user = create(:user)
      ActsAsTenant.with_tenant(organisation) { create(:membership, user: user, organisation: organisation, role: admin_role, active: true) }
      user
    end

    before { sign_in admin }

    it 'shows the connect CTA + both motivation copies when no repo is connected yet' do
      get edit_path
      expect(response.body).to include(I18n.t('views.organisations.projects.edit.connect_repository'))
      expect(response.body).not_to include(I18n.t('views.organisations.projects.edit.manage_repositories'))
      # Chat-enabled org → the copy that promises chat code-context (kills the
      # "chat card always hidden" mutation, which stays green in the chat-less spec).
      expect(response.body).to include(I18n.t('views.organisations.projects.edit.chat_with_code_empty'))
      expect(response.body).to include(I18n.t('views.organisations.projects.edit.documentation_empty'))
    end

    it 'lists connected repos (name) and switches the CTA to "manage"' do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_repository, project: project, organisation: organisation, full_name: 'acme/backend')
      end
      get edit_path
      expect(response.body).to include('acme/backend')
      expect(response.body).to include(I18n.t('views.organisations.projects.edit.manage_repositories'))
    end

    it 'shows the index status in the chat card when chat is enabled' do
      ActsAsTenant.with_tenant(organisation) do
        repo = create(:project_repository, project: project, organisation: organisation, full_name: 'acme/backend')
        create(:project_index, project_repository: repo, status: 'ready')
      end
      get edit_path
      expect(response.body).to include(I18n.t('views.organisations.indexing.status.ready'))
    end

    it 'surfaces a FAILED index as a health warning in the chat card (not just a link)' do
      ActsAsTenant.with_tenant(organisation) do
        repo = create(:project_repository, project: project, organisation: organisation, full_name: 'acme/backend')
        create(:project_index, project_repository: repo, status: 'failed')
      end
      get edit_path
      expect(response.body).to include(I18n.t('views.organisations.indexing.status.failed'))
    end

    it 'shows the doc-sync status in the documentation card when a set exists' do
      ActsAsTenant.with_tenant(organisation) do
        repo = create(:project_repository, project: project, organisation: organisation, full_name: 'acme/backend')
        create(:documentation_set, project: project, project_repository: repo, organisation: organisation, sync_status: 'ready')
      end
      get edit_path
      expect(response.body).to include(I18n.t('views.organisations.documentation.sync_status.ready'))
    end

    it 'reads a repo without any documentation set as "never synced" in the documentation card' do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_repository, project: project, organisation: organisation, full_name: 'acme/backend')
      end
      get edit_path
      expect(response.body).to include(I18n.t('views.organisations.documentation.sync_status.never_synced'))
    end
  end

  describe 'the chat card is org-gated (no dead promise for a chat-less org)' do
    let(:organisation) { create(:organisation, code_indexing_enabled: false) }
    let(:admin_role) { create(:admin_role, organisation: organisation) }
    let(:admin) do
      user = create(:user)
      ActsAsTenant.with_tenant(organisation) { create(:membership, user: user, organisation: organisation, role: admin_role, active: true) }
      user
    end

    before { sign_in admin }

    it 'omits the chat card entirely but keeps the documentation card' do
      get edit_path
      expect(response.body).not_to include(chat_card_title)
      expect(response.body).not_to include(I18n.t('views.organisations.projects.edit.chat_with_code_empty'))
      expect(response.body).to include(docs_card_title)
      expect(response.body).to include(I18n.t('views.organisations.projects.edit.documentation_empty'))
    end

    it 'omits the index status for a chat-less org even if an index row exists' do
      ActsAsTenant.with_tenant(organisation) do
        repo = create(:project_repository, project: project, organisation: organisation, full_name: 'acme/backend')
        create(:project_index, project_repository: repo, status: 'ready')
      end
      get edit_path
      expect(response.body).to include('acme/backend') # repo still listed (documentation card)
      expect(response.body).not_to include(I18n.t('views.organisations.indexing.status.ready'))
    end
  end

  describe 'view-only tier (chats:read, cannot manage)' do
    let(:viewer) { settings_visitor(project_access: { chats_access: 'read_only' }) }

    before { sign_in viewer }

    it 'offers "view" but not "manage" when a repo exists' do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_repository, project: project, organisation: organisation, full_name: 'acme/backend')
      end
      get edit_path
      expect(response.body).to include(I18n.t('views.organisations.projects.edit.view_repositories'))
      expect(response.body).not_to include(I18n.t('views.organisations.projects.edit.manage_repositories'))
    end

    it 'shows NO button to a view-only visitor when no repo exists (dead affordance avoided)' do
      # Kills the mutation `elsif repositories.any?` → `else`, which would offer a
      # "view repositories" button leading to an empty page.
      get edit_path
      expect(response.body).not_to include(I18n.t('views.organisations.projects.edit.view_repositories'))
      expect(response.body).not_to include(I18n.t('views.organisations.projects.edit.manage_repositories'))
    end
  end

  describe 'no-permission tier (tickets only)' do
    let(:outsider) { settings_visitor(project_access: { tickets_access: 'read_only' }) }

    before { sign_in outsider }

    it 'shows ONE neutral card: hint, no action button, no repo name (no existence leak)' do
      ActsAsTenant.with_tenant(organisation) do
        create(:project_repository, project: project, organisation: organisation, full_name: 'acme/secret-repo')
      end
      get edit_path
      # The title contains "&" → compare HTML-escaped, as it leaves the ERB escaper.
      expect(response.body).to include(CGI.escapeHTML(I18n.t('views.organisations.projects.edit.code_and_docs_title')))
      expect(response.body).to include(I18n.t('views.organisations.projects.edit.repositories_no_permission'))
      expect(response.body).not_to include('acme/secret-repo')
      expect(response.body).not_to include(chat_card_title)
      expect(response.body).not_to include(docs_card_title)
      expect(response.body).not_to include(I18n.t('views.organisations.projects.edit.manage_repositories'))
      expect(response.body).not_to include(I18n.t('views.organisations.projects.edit.view_repositories'))
    end
  end
end
