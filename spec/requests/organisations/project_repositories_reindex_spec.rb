# frozen_string_literal: true

require 'rails_helper'

# Covers the manual "reindex now" trigger (POST reindex): who may fire it, that it
# enqueues an incremental RepoReindexJob attributed to the clicking user, and that
# it refuses to stack a second run while one is already in flight.
RSpec.describe 'Project repository manual reindex', type: :request do
  include ActiveJob::TestHelper

  # R4 (doc/ai_feature_registry_plan.md): the index UI stopped asking the bare opt-in and
  # asks :repository_indexing, which wants a usable configuration on BOTH lanes — the
  # indexer builds a chat provider for the layer-4 summaries and an embedding provider for
  # the fragments. The factory org carries the opt-in but no credential, so without these
  # the reindex button is (correctly) withheld and this file's subject never renders.
  let(:organisation) do
    create(:organisation, code_indexing_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-test-1234567890abcdef',
                          embedding_access_token: 'sk-test-1234567890abcdef')
  end
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:repository) do
    ActsAsTenant.with_tenant(organisation) do
      create(:project_repository, project: project, organisation: organisation, full_name: 'acme/x')
    end
  end

  # A repo's index is auto-created 'pending' on connect; a settled 'ready' state
  # is the precondition for a manual reindex.
  def mark_index_ready!
    repository.project_index.update!(status: 'ready')
  end

  def reindex_path
    reindex_organisation_project_project_repository_path(organisation, project, repository)
  end

  def membership_for(user, role)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    ActsAsTenant.current_tenant = organisation
  end
  after { ActsAsTenant.current_tenant = nil }

  context 'as a chats-write user (admin)' do
    let(:user) { create(:user) }
    let(:role) { create(:admin_role, organisation: organisation) }
    before do
      membership_for(user, role)
      mark_index_ready!
      sign_in user
    end

    it 'enqueues an incremental RepoReindexJob tagged manual and attributed to the user' do
      expect { post reindex_path }
        .to have_enqueued_job(RepoReindexJob)
        .with(repository, trigger: 'manual', triggered_by_user_id: user.id)
    end

    it 'redirects back to the repositories page with a started notice' do
      post reindex_path
      expect(response).to redirect_to(organisation_project_project_repositories_path(organisation, project))
      expect(flash[:notice]).to eq(I18n.t('flash.project_repositories.reindex.started', name: 'acme/x'))
    end

    it 'refuses and does NOT enqueue while an index run is already in flight' do
      repository.project_index.update!(status: 'indexing')

      expect { post reindex_path }.not_to have_enqueued_job(RepoReindexJob)
      expect(flash[:notice]).to eq(I18n.t('flash.project_repositories.reindex.already_running', name: 'acme/x'))
    end
  end

  context 'as a chats-read-only user' do
    let(:user) { create(:user) }
    let(:role) do
      r = create(:role, title: 'Chat Reader', organisation: organisation)
      create(:permission, role: r, category: 'projects', action: 'read_access_chats_all_projects', allowed: true)
      r
    end
    before do
      membership_for(user, role)
      mark_index_ready!
      sign_in user
    end

    it 'is denied (reindex is administrative) and enqueues nothing' do
      expect { post reindex_path }.not_to have_enqueued_job(RepoReindexJob)
      expect(response).to have_http_status(:redirect) # Pundit not-authorized redirect
    end
  end

  context 'when the per-org chat beta feature is off (behaviour-gated: policy authorises, controller refuses)' do
    let(:user) { create(:user) }
    let(:role) { create(:admin_role, organisation: organisation) }
    before do
      membership_for(user, role)
      mark_index_ready!
      organisation.update!(code_indexing_enabled: false)
      sign_in user
    end

    # The repo policy is DECOUPLED from the chat beta — the admin passes reindex?
    # (see project_repository_policy_spec), so this is NOT a Pundit denial. But
    # indexing itself stays chat-gated, so the controller behaviour-gate refuses the
    # direct POST with an honest alert instead of enqueuing a guaranteed no-op job
    # and claiming "reindex started". (The reindex button is also hidden in the UI.)
    it 'refuses via the behaviour gate: enqueues nothing and shows the feature-disabled alert' do
      # Guard against a tautological flash check: if the key were deleted, both the
      # controller t() and the assertion would yield the same "missing" string. Pin
      # that the key actually exists, THEN compare.
      expect(I18n.exists?('flash.project_repositories.reindex.feature_disabled', :de)).to be(true)
      expect { post reindex_path }.not_to have_enqueued_job(RepoReindexJob)
      expect(response).to redirect_to(organisation_project_project_repositories_path(organisation, project))
      expect(flash[:alert]).to eq(I18n.t('flash.project_repositories.reindex.feature_disabled'))
    end
  end

  # GDPR AI opt-in (audit 2026-07-03): the jobs gate on code_indexing_enabled AND
  # ai_enabled — the controller must mirror BOTH halves. Kills the red-team
  # finding: chat-enabled/AI-disabled org clicked reindex, got a false
  # "reindex started" notice for a job that silently no-oped.
  context 'when chat is enabled but the org has not opted in to AI' do
    let(:user) { create(:user) }
    let(:role) { create(:admin_role, organisation: organisation) }
    before do
      membership_for(user, role)
      mark_index_ready!
      organisation.update!(code_indexing_enabled: true, ai_enabled: false)
      sign_in user
    end

    it 'refuses honestly: enqueues nothing and explains the missing AI opt-in' do
      expect { post reindex_path }.not_to have_enqueued_job(RepoReindexJob)
      expect(response).to redirect_to(organisation_project_project_repositories_path(organisation, project))
      expect(flash[:alert]).to eq(I18n.t('shared.ai.disabled_admin_hint'))
    end
  end

  # R4 widened the BUTTON from the bare opt-in to :repository_indexing (both lanes),
  # and this guard had to follow or the pair drifts apart: an opted-in org whose
  # embedding lane cannot serve — chatting on Anthropic, or simply missing the
  # embedding credential — sees no button any more, while a direct POST or a stale tab
  # still collected "reindex started" for a run that settles as failed. That is the
  # false success the comment above this context says the guard exists to prevent, one
  # registry row later.
  context 'when the org is opted in but the indexing feature is unavailable' do
    let(:user) { create(:user) }
    let(:role) { create(:admin_role, organisation: organisation) }

    before do
      membership_for(user, role)
      mark_index_ready!
      # Key-scoped, never blanket: a bare receive(:resolve) answers for EVERY row and
      # would make this example blind to the guard asking a different one (#402 review).
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve)
        .with(:repository_indexing, anything)
        .and_return(Lalabase::Llm::FeatureRegistry::Availability.new(
                      available: false, reason: :provider_incapable,
                      required_provider: 'anthropic', lane: :embedding
                    ))
      sign_in user
    end

    it 'refuses the POST and names the lane instead of reporting a start' do
      expect { post reindex_path }.not_to have_enqueued_job(RepoReindexJob)
      expect(response).to redirect_to(organisation_project_project_repositories_path(organisation, project))
      expect(flash[:alert]).to eq(
        I18n.t('shared.ai.unavailable.provider_incapable',
               provider: AiCredential.provider_display_names.fetch('anthropic', 'anthropic'),
               current: AiCredential.provider_display_names.fetch('openai', 'openai'))
      )
      expect(flash[:notice]).to be_blank
    end

    it 'still lets a refusal aimed at another registry row through' do
      # The mutation half: every row answers the same for this fully configured org, so
      # retyping the guard's key would leave the example above green. Only a FOREIGN
      # refusal that changes nothing here shows the guard really reads
      # :repository_indexing.
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve)
        .with(:chat, anything)
        .and_return(Lalabase::Llm::FeatureRegistry::Availability.new(
                      available: false, reason: :no_credential, required_provider: 'openai'
                    ))
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve)
        .with(:repository_indexing, anything).and_call_original

      expect { post reindex_path }.to have_enqueued_job(RepoReindexJob)
    end
  end

  # Renders the real index page — verifies the button is wired (route helper,
  # POST target) and only shown for a settled index.
  context 'reindex button visibility on the repositories index' do
    let(:user) { create(:user) }
    let(:role) { create(:admin_role, organisation: organisation) }
    before do
      membership_for(user, role)
      sign_in user
    end

    def index_page
      get organisation_project_project_repositories_path(organisation, project)
    end

    it 'shows the reindex button, targeting the reindex path, when the index is ready' do
      repository.project_index.update!(status: 'ready')
      index_page
      expect(response.body).to include(I18n.t('views.organisations.indexing.reindex.button'))
      expect(response.body).to include(reindex_path) # POST target wired via the route helper
    end

    it 'hides the reindex button while an index run is in flight' do
      repository.project_index.update!(status: 'indexing')
      index_page
      expect(response.body).not_to include(I18n.t('views.organisations.indexing.reindex.button'))
    end
  end

  context 'for a repository in another organisation' do
    let(:user) { create(:user) }
    let(:role) { create(:admin_role, organisation: organisation) }
    let(:other_org) { create(:organisation, code_indexing_enabled: true) }
    let(:foreign_repo) do
      ActsAsTenant.with_tenant(other_org) do
        create(:project_repository, project: create(:project, organisation: other_org), organisation: other_org)
      end
    end
    before do
      membership_for(user, role)
      sign_in user
    end

    it 'cannot be reindexed through this project (scoped find misses it)' do
      path = reindex_organisation_project_project_repository_path(organisation, project, foreign_repo)
      expect { post path }.not_to have_enqueued_job(RepoReindexJob)
      expect(response).to have_http_status(:not_found)
    end
  end
end
