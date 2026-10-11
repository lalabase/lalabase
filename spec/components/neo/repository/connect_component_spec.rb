# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Neo::Repository::ConnectComponent, type: :component do
  # Index/webhook UI is behaviour-gated on the per-org chat beta (see
  # #indexing_ui_enabled?). The default org here enables chat so the existing
  # index/webhook/subscription specs exercise the "normal" chat-org rendering; the
  # chat-less gating gets its own describe below.
  #
  # R4 (doc/ai_feature_registry_plan.md): that gate stopped asking the bare opt-in and
  # asks :repository_indexing — the ONE registry row declaring both lanes, because
  # ProjectIndexerJob builds a chat provider for the layer-4 summaries AND an embedding
  # provider for the fragments. Hence two credentials here rather than one: with only the
  # chat token the embedding lane refuses and the index UI vanishes from every example.
  let(:organisation) do
    create(:organisation, code_indexing_enabled: true,
                          ai_provider: 'openai', ai_access_token: 'sk-test-1234567890abcdef',
                          embedding_access_token: 'sk-test-1234567890abcdef')
  end
  let(:project)      { create(:project, organisation: organisation) }
  let(:new_repo)     { ProjectRepository.new(project: project, organisation: organisation, provider: 'github') }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def stub_helpers
    fake = double('helpers').as_null_object
    allow(fake).to receive(:organisation_project_project_repository_path).and_return('/disconnect-path')
    allow(fake).to receive(:organisation_project_project_repositories_path).and_return('/create-path')
    allow(fake).to receive(:protect_against_forgery?).and_return(false)
    allow_any_instance_of(described_class).to receive(:helpers).and_return(fake)
    fake
  end

  def render_with(repositories: [], new_repository: new_repo, can_manage: true, can_connect: true, origin: nil)
    component = described_class.new(project: project, repositories: repositories,
                                    new_repository: new_repository, current_organisation: organisation,
                                    origin: origin)
    # can_manage? / can_connect? wrap Pundit (helpers.policy), which needs a
    # current_user that isolated component specs don't have — stub the predicates
    # directly (same seam the chat components use). Both default true so the
    # existing specs keep exercising the full row + form.
    allow(component).to receive(:can_manage?).and_return(can_manage)
    allow(component).to receive(:can_connect?).and_return(can_connect)
    render_inline(component)
  end

  describe 'empty state' do
    it 'renders the empty hint when no repositories are connected' do
      stub_helpers
      render_with(repositories: [])
      expect(rendered_content).to include(I18n.t('views.organisations.project_repositories.index.empty'))
    end

    it 'still renders the add-new form even when list is empty' do
      stub_helpers
      render_with(repositories: [])
      expect(page).to have_css('input[name="project_repository[full_name]"]')
      expect(page).to have_css('input[name="project_repository[access_token]"][type="password"]')
    end
  end

  describe 'connected list' do
    let(:repo_a) { create(:project_repository, project: project, full_name: 'acme/backend',  default_branch: 'main') }
    let(:repo_b) { create(:project_repository, project: project, full_name: 'acme/frontend', default_branch: 'develop') }

    it 'renders one row per connected repository' do
      stub_helpers
      render_with(repositories: [repo_a, repo_b])
      expect(rendered_content).to include('acme/backend').and include('acme/frontend')
    end

    it 'shows the default branch of each repo (catches branch column removed)' do
      stub_helpers
      render_with(repositories: [repo_a, repo_b])
      expect(rendered_content).to include('main')
      expect(rendered_content).to include('develop')
    end

    it 'each disconnect link uses DELETE method and turbo_confirm' do
      stub_helpers
      render_with(repositories: [repo_a])
      expect(page).to have_css('a[data-turbo-method="delete"][data-turbo-confirm]')
    end

    # Catches mutation: removed `each` loop — first repo would still render the
    # button but additional repos would silently lose their disconnect link.
    it 'renders exactly one disconnect button per connected repository' do
      stub_helpers
      render_with(repositories: [repo_a, repo_b])
      expect(page).to have_css('a[data-turbo-method="delete"]', count: 2)
    end

    it 'disconnect link points to repo-specific path (not collection path)' do
      fake = stub_helpers
      expect(fake).to receive(:organisation_project_project_repository_path)
        .with(organisation, project, repo_a).and_return('/specific-disconnect')
      render_with(repositories: [repo_a])
      expect(page).to have_css('a[href="/specific-disconnect"]')
    end
  end

  describe 'form contract' do
    before { stub_helpers }

    it 'access_token input is password-type (no shoulder-surf leak)' do
      render_with
      expect(page).to have_css('input[name="project_repository[access_token]"][type="password"]')
    end

    it 'access_token input has autocomplete=off (no browser-save of PATs)' do
      render_with
      expect(page).to have_css('input[name="project_repository[access_token]"][autocomplete="off"]')
    end

    it 'full_name input has autocomplete=off (no autofill leakage between connects)' do
      render_with
      expect(page).to have_css('input[name="project_repository[full_name]"][autocomplete="off"]')
    end

    it 'submits via POST' do
      render_with
      expect(page).to have_css('form[method="post"]')
    end

    it 'PAT help link opens in a new tab with rel=noopener (security)' do
      render_with
      expect(page).to have_css('a[target="_blank"][rel*="noopener"]')
    end

    # Catches mutation: PAT help URL swapped to a phishing or staging host.
    it 'PAT help link points to github.com/settings/personal-access-tokens/new exactly' do
      render_with
      link = page.find('a[target="_blank"]')
      expect(link['href']).to eq('https://github.com/settings/personal-access-tokens/new')
    end
  end

  describe 'error rendering' do
    it 'lists each validation error from new_repository' do
      bad_repo = new_repo
      bad_repo.errors.add(:access_token, :invalid, message: 'Bad credentials')
      bad_repo.errors.add(:full_name,    :not_found, message: 'Not Found')
      stub_helpers
      render_with(new_repository: bad_repo)
      expect(rendered_content).to include('Bad credentials')
      expect(rendered_content).to include('Not Found')
    end

    it 'does NOT render the error box when there are no errors' do
      stub_helpers
      render_with
      expect(page).not_to have_css('.border-red-300')
    end
  end

  describe 'i18n linkage (catches key vs locale drift)' do
    it 'renders the literal German empty-state phrase when locale is :de' do
      stub_helpers
      I18n.with_locale(:de) do
        render_with(repositories: [])
        expect(rendered_content).to include('Noch kein Repository verbunden')
      end
    end
  end

  describe 'webhook setup (write-gated)' do
    let(:repo) { create(:project_repository, project: project, full_name: 'acme/backend') }

    it 'shows the webhook secret + setup block to users who can manage the repo' do
      stub_helpers
      render_with(repositories: [repo], can_manage: true)
      expect(rendered_content).to include(repo.webhook_secret)
      expect(rendered_content).to include(I18n.t('views.organisations.indexing.webhook.title'))
    end

    # Security: the per-repo HMAC secret must never reach read-only users.
    it 'hides the webhook secret + setup block from users who cannot manage the repo' do
      stub_helpers
      render_with(repositories: [repo], can_manage: false)
      expect(rendered_content).not_to include(repo.webhook_secret)
      expect(rendered_content).not_to include(I18n.t('views.organisations.indexing.webhook.title'))
    end

    it 'renders an independent copy widget + readonly source for url AND secret' do
      stub_helpers
      render_with(repositories: [repo], can_manage: true)
      expect(page).to have_css('[data-controller="clipboard"]', count: 2)
      expect(page).to have_css('input[readonly][data-clipboard-target="source"]', count: 2)
    end
  end

  describe 'live-status subscription wiring' do
    let(:repo) { create(:project_repository, project: project, full_name: 'acme/backend') }

    it 'subscribes to the per-repo index stream when an index exists' do
      fake = stub_helpers
      create(:project_index, project_repository: repo, status: 'indexing')
      expect(fake).to receive(:turbo_stream_from).with(repo.organisation, :project_index, repo.id)
      render_with(repositories: [repo.reload], can_manage: false)
    end
  end

  # R4 (doc/ai_feature_registry_plan.md): the index UI asks :repository_indexing instead
  # of the bare opt-in, so an org that cannot actually index stops being offered the
  # status badge, the reindex button and the webhook setup for a pipeline that settles
  # as failed.
  describe 'the index UI asks the :repository_indexing feature (R4)' do
    let(:repo_one) { create(:project_repository, project: project, full_name: 'acme/backend') }
    let(:repo_two) { create(:project_repository, project: project, full_name: 'acme/frontend') }

    # Key-scoped: a blanket `receive(:resolve)` would answer for every key and make this
    # file blind to a mistyped one (#402 review).
    def refuse_only(feature_key, reason: :no_credential)
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve).and_call_original
      allow(Lalabase::Llm::FeatureRegistry).to receive(:resolve)
        .with(feature_key, anything)
        .and_return(Lalabase::Llm::FeatureRegistry::Availability.new(
                      available: false, reason: reason, required_provider: 'openai', lane: :embedding
                    ))
    end

    def hint_text
      label = AiCredential.provider_display_names.fetch('openai', 'openai')
      I18n.t('shared.ai.unavailable.no_credential', provider: label, current: label)
    end

    it 'shows the webhook setup while both lanes are configured' do
      stub_helpers
      render_with(repositories: [repo_one], can_manage: true)

      expect(rendered_content).to include(I18n.t('views.organisations.indexing.webhook.title'))
      expect(rendered_content).not_to include(hint_text)
    end

    it 'withholds the index UI and names the reason when the feature is refused' do
      refuse_only(:repository_indexing)
      stub_helpers
      render_with(repositories: [repo_one], can_manage: true)

      expect(rendered_content).not_to include(I18n.t('views.organisations.indexing.webhook.title'))
      expect(rendered_content).to include(hint_text)
      # The reason sentence is row-independent, so it alone cannot show WHICH key the
      # hint was told to name. Retyping `feature: :repository_indexing` to any other
      # registry key would leave every other example here green — the document surfaces
      # already discriminate this way via indexing_label / summary_label.
      expect(rendered_content).to include(I18n.t('shared.ai.features.repository_indexing'))
    end

    it 'says it once for the whole list, not once per repository' do
      refuse_only(:repository_indexing)
      stub_helpers
      render_with(repositories: [repo_one, repo_two], can_manage: true)

      expect(rendered_content.scan(hint_text).size).to eq(1)
    end

    it 'ignores a refusal aimed at a different registry row' do
      # The mutation half: every row answers the same for a fully configured org, so a
      # foreign key would pass the positive example above. Only a FOREIGN refusal that
      # leaves this UI intact shows the gate really reads :repository_indexing.
      refuse_only(:chat)
      stub_helpers
      render_with(repositories: [repo_one], can_manage: true)

      expect(rendered_content).to include(I18n.t('views.organisations.indexing.webhook.title'))
      expect(rendered_content).not_to include(hint_text)
    end

    # Plan §7.6 (the #368 lesson): this gate sits INSIDE the repository loop and is asked
    # twice per row, and unlike the attribute read it replaced it can reach
    # AiCredential.active_for_provider — a Solid-Cache SELECT in production.
    #
    # TWO memos sit on this path and they must be measured SEPARATELY, or the guard is
    # vacuum-green: the component's own memo and Organisation#ai_available_for?'s cache
    # answer the same question, so a `resolve` count alone stays at one when EITHER is
    # deleted and only moves when both are. Counting the component→model call pins the
    # component memo; counting resolve pins that the model does not re-resolve behind it.
    # Deliberately measured with a refused feature: an org that resolves early would hide
    # the very cost this pins.
    it 'asks the organisation once for the whole list, not twice per repository' do
      refuse_only(:repository_indexing)
      allow(organisation).to receive(:ai_available_for?).and_call_original
      stub_helpers
      render_with(repositories: [repo_one, repo_two], can_manage: true)

      # indexing_ui_enabled? + show_indexing_unavailable_hint? per row = 4 asks without
      # the component memo, for two repositories.
      expect(organisation).to have_received(:ai_available_for?).with(:repository_indexing).once
    end

    it 'resolves the feature once for the whole list' do
      refuse_only(:repository_indexing)
      stub_helpers
      render_with(repositories: [repo_one, repo_two], can_manage: true)

      expect(Lalabase::Llm::FeatureRegistry).to have_received(:resolve)
        .with(:repository_indexing, anything).once
    end

    context 'when the org never opted in' do
      let(:organisation) { create(:organisation, :ai_disabled, code_indexing_enabled: true) }

      it 'stays silent exactly as it did before R4' do
        # R4 replaces switches that a missing CONFIGURATION made useless. A surface that
        # said nothing about the opt-in keeps saying nothing — the opt-in has its own
        # place (the AI settings), and a repo page is not it.
        stub_helpers
        render_with(repositories: [repo_one], can_manage: true)

        expect(rendered_content).not_to include(I18n.t('views.organisations.indexing.webhook.title'))
        expect(rendered_content).not_to include(I18n.t('shared.ai.disabled_member_hint'))
      end
    end
  end

  # Read-only hardening (plan 1e): ProjectRepositoryPolicy#index? needs only
  # chats:read, so a read-only visitor reaches this page by URL. Every WRITE
  # affordance (disconnect, the connect form) must be hidden for them — otherwise
  # it just 403s on submit. The webhook/token blocks were already gated; these two
  # were not.
  describe 'read-only hardening (1e)' do
    let(:repo) { create(:project_repository, project: project, full_name: 'acme/backend') }

    it 'hides the disconnect button from a read-only visitor (can_manage? false)' do
      stub_helpers
      render_with(repositories: [repo], can_manage: false)
      expect(page).not_to have_css('a[data-turbo-method="delete"]')
    end

    it 'shows the disconnect button to a manager (guards the gate is not always-off)' do
      stub_helpers
      render_with(repositories: [repo], can_manage: true)
      expect(page).to have_css('a[data-turbo-method="delete"]', count: 1)
    end

    it 'hides the entire connect form from a visitor who cannot connect' do
      stub_helpers
      render_with(repositories: [repo], can_manage: false, can_connect: false)
      expect(page).not_to have_css('input[name="project_repository[full_name]"]')
      expect(page).not_to have_css('input[name="project_repository[access_token]"]')
    end

    it 'shows the connect form to a user who may connect but manages nothing yet' do
      stub_helpers
      render_with(repositories: [], can_manage: false, can_connect: true)
      expect(page).to have_css('input[name="project_repository[full_name]"]')
    end
  end

  # Origin round-trip (plan 1d): the marker must ride through the form as a HIDDEN
  # field, because a failed connect re-renders THIS form (render :new) — a query
  # param would be lost there, a hidden field is not.
  describe 'origin round-trip hidden field (1d)' do
    it 'embeds origin as a hidden field so it survives a failed connect' do
      stub_helpers
      render_with(origin: 'documentation')
      expect(page).to have_css('input[type="hidden"][name="origin"][value="documentation"]', visible: :all)
    end

    it 'renders NO origin field in the plain connect flow (origin nil)' do
      stub_helpers
      render_with # origin defaults to nil
      expect(page).not_to have_css('input[name="origin"]', visible: :all)
    end
  end

  # Behaviour gating (plan Phase 2): a chat-less org can CONNECT a repo (for doc
  # sync) but never builds a code index, and its push webhook no-ops. So the
  # index/reindex/history/webhook UI must NOT be shown — it would read as a broken
  # "never indexed" state. Token rotation stays (doc sync uses the same PAT).
  describe 'chat-less org (code_indexing_enabled: false)' do
    let(:organisation) { create(:organisation, code_indexing_enabled: false) }
    let(:repo)         { create(:project_repository, project: project, full_name: 'acme/backend') }

    it 'hides the webhook setup block even for a manager' do
      stub_helpers
      render_with(repositories: [repo], can_manage: true)
      expect(rendered_content).not_to include(I18n.t('views.organisations.indexing.webhook.title'))
      expect(rendered_content).not_to include(repo.webhook_secret)
    end

    it 'says nothing about the AI feature either — the chat beta is a different gate' do
      # R4's hint is withheld while the chat beta is off, and that half of
      # show_indexing_unavailable_hint? has nothing else guarding it: this org carries the
      # opt-in (factory default) and no credential, so :repository_indexing resolves
      # unavailable and deleting `code_indexing_enabled? &&` would make the hint appear
      # here. The beta is a different gate with a different remedy, and an org that has
      # not asked for an index should not be told why it has none.
      stub_helpers
      render_with(repositories: [repo], can_manage: true)

      label = AiCredential.provider_display_names.fetch('openai', 'openai')
      expect(rendered_content).not_to include(
        I18n.t('shared.ai.unavailable.no_credential', provider: label, current: label)
      )
      expect(rendered_content).not_to include(I18n.t('shared.ai.features.repository_indexing'))
    end

    it 'still shows token rotation to a manager (doc sync needs an unexpired PAT)' do
      stub_helpers
      render_with(repositories: [repo], can_manage: true)
      expect(rendered_content).to include(I18n.t('views.organisations.indexing.token_update.title'))
    end

    it 'hides index status / history / reindex even if an index somehow exists' do
      fake = stub_helpers
      create(:project_index, project_repository: repo, status: 'ready')
      # No index stream subscription and no run-history link when chat is off.
      expect(fake).not_to receive(:turbo_stream_from)
      render_with(repositories: [repo.reload], can_manage: true)
      expect(rendered_content).not_to include(I18n.t('views.organisations.indexing.runs.link'))
    end

    it 'still renders the connected repo and the add-new form (connect is allowed)' do
      stub_helpers
      render_with(repositories: [repo], can_manage: true)
      expect(rendered_content).to include('acme/backend')
      expect(page).to have_css('input[name="project_repository[full_name]"]')
    end
  end
end
