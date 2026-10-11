# frozen_string_literal: true

require 'rails_helper'

# Documentation → repository entry points (plan 1c): the empty-state CTAs and the
# persistent overflow-menu link, driven through the REAL controllers so the
# @can_connect_repo / @project_has_repository wiring is exercised end-to-end.
#
# The relocation started from a concrete dead end: the doc set-creation page
# required a repo but offered no way to connect one. These guard that the way out
# now exists for those who may connect, and is a neutral hint for those who may not.
RSpec.describe 'Documentation — repository entry points', type: :request do
  let(:organisation) { create(:organisation, code_indexing_enabled: true) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def doc_index_path = organisation_project_documentation_index_path(organisation, project)
  def new_set_path = new_organisation_project_documentation_set_path(organisation, project)
  def repo_path = organisation_project_project_repositories_path(organisation, project)

  # A user with an arbitrary mix of project-area grants (one ProjectPermission row).
  def project_user(**access)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(3)}", is_default: true)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      ProjectPermission.create!({ user: user, project: project }.merge(access))
    end
    user
  end

  # documentation:read is enough to enter the area; read_write also grants repo
  # management + set management.
  def doc_user(access) = project_user(documentation_access: access)

  let(:doc_writer) { doc_user('read_write') }
  let(:doc_reader) { doc_user('read_only') }
  # Cross-area persona: may CONNECT a repo (chats:write) but may NOT create a doc set
  # (documentation:read). Exactly the user who used to hit a post-connect 403 when
  # the doc-index CTA keyed off can_connect_repo alone.
  let(:chat_writer_doc_reader) { project_user(chats_access: 'read_write', documentation_access: 'read_only') }

  describe 'index empty state (no set)' do
    context 'no repo connected yet' do
      it 'offers the repo-connect CTA (origin round-trip) to a documentation manager' do
        sign_in doc_writer
        get doc_index_path
        expect(response.body).to include(I18n.t('views.organisations.documentation.empty.connect_repository'))
        expect(response.body).to include("#{repo_path}?origin=documentation")
      end

      it 'shows only a neutral hint to a documentation reader (may not connect)' do
        sign_in doc_reader
        get doc_index_path
        expect(response.body).to include(I18n.t('views.organisations.documentation.empty.setup_no_permission'))
        expect(response.body).not_to include(I18n.t('views.organisations.documentation.empty.connect_repository'))
      end

      # [Major] regression guard: a chats:write + doc:read user CAN connect a repo,
      # but the round-trip lands on set-creation (documentation:write). Offering the
      # CTA here produced a post-connect 403. It must be suppressed → neutral hint.
      it 'does NOT offer the connect CTA to a chats:write + doc:read user (no 403 dead-end)' do
        sign_in chat_writer_doc_reader
        get doc_index_path
        expect(response.body).to include(I18n.t('views.organisations.documentation.empty.setup_no_permission'))
        expect(response.body).not_to include(I18n.t('views.organisations.documentation.empty.connect_repository'))
      end
    end

    context 'a repo exists but no set yet' do
      before do
        ActsAsTenant.with_tenant(organisation) do
          create(:project_repository, project: project, organisation: organisation, full_name: 'acme/backend')
        end
      end

      it 'points the manager at set-creation, NOT back at repo-connect' do
        sign_in doc_writer
        get doc_index_path
        expect(response.body).to include(I18n.t('views.organisations.documentation.index.connect'))
        expect(response.body).not_to include(I18n.t('views.organisations.documentation.empty.connect_repository'))
      end
    end
  end

  describe 'persistent overflow link in the NON-empty state (AK 7: token rotation path)' do
    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:documentation_set, project: project, organisation: organisation)
      end
    end

    it 'shows a "manage repository" link (carrying origin) to a manager even when a set exists' do
      sign_in doc_writer
      get doc_index_path
      expect(response.body).to include(I18n.t('views.organisations.documentation.index.manage_repository'))
      # origin=documentation so the repo page's back link returns to the docs area
      # (which this AK7 persona can read) rather than 403-ing on settings.
      expect(response.body).to include("#{repo_path}?origin=documentation")
    end

    it 'hides the "manage repository" link from a documentation reader' do
      sign_in doc_reader
      get doc_index_path
      expect(response.body).not_to include(I18n.t('views.organisations.documentation.index.manage_repository'))
    end
  end

  describe 'set-creation page with no repositories (the original dead end)' do
    it 'offers a repo-connect CTA (origin round-trip) instead of a bare warning' do
      sign_in doc_writer
      get new_set_path
      expect(response.body).to include(I18n.t('views.organisations.documentation.new.connect_repository'))
      expect(response.body).to include("#{repo_path}?origin=documentation")
    end
  end
end
