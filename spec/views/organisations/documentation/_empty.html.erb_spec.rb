# frozen_string_literal: true

require 'rails_helper'

# The documentation empty-state carries TWO distinct permission flags on purpose
# (plan 1c): can_manage_sets (DocumentationSetPolicy#create?) and can_connect_repo
# (ProjectRepositoryPolicy#create?). Through real personas the two mostly move
# together (doc:read → both false, doc:write → both true), so only a unit render
# with DIVERGENT flags proves the branching keys off the RIGHT one — and guards a
# future dev from collapsing them back into a single `can_manage`.
RSpec.describe 'organisations/documentation/_empty', type: :view do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  before do
    ActsAsTenant.current_tenant = organisation
    assign(:current_organisation, organisation)
    assign(:project, project)
  end

  after { ActsAsTenant.current_tenant = nil }

  def render_empty(variant:, can_manage_sets:, can_connect_repo:, project_has_repository:)
    render partial: 'organisations/documentation/empty',
           locals: { variant: variant, can_manage_sets: can_manage_sets,
                     can_connect_repo: can_connect_repo, project_has_repository: project_has_repository }
    Nokogiri::HTML.fragment(rendered)
  end

  let(:connect_repo_label) { I18n.t('views.organisations.documentation.empty.connect_repository') }
  let(:create_set_label) { I18n.t('views.organisations.documentation.index.connect') }
  let(:setup_hint) { I18n.t('views.organisations.documentation.empty.setup_no_permission') }

  # :no_set + no repo: the repo-connect CTA requires BOTH flags. can_connect_repo
  # alone (e.g. chats:write + documentation:read) is NOT enough — the round-trip
  # lands on set-creation, which needs documentation:write; offering the CTA there
  # would be a post-connect 403 dead-end (plan AK1/AK5). So the CTA keys off the AND,
  # and either flag alone falls through to the neutral hint.
  describe ':no_set with NO repo — connect CTA needs can_connect_repo AND can_manage_sets' do
    it 'shows the repo-connect CTA (origin round-trip) when BOTH flags are set' do
      doc = render_empty(variant: :no_set, can_manage_sets: true, can_connect_repo: true, project_has_repository: false)
      expect(doc.text).to include(connect_repo_label)
      href = doc.at_css('a')['href']
      expect(href).to include(organisation_project_project_repositories_path(organisation, project))
      expect(href).to include('origin=documentation')
    end

    it 'falls to the neutral hint when the user may connect but NOT manage sets (chats:write + doc:read)' do
      # The exact cross-area persona that used to 403 after connecting: it CAN connect
      # (chats:write) but cannot create the set. No CTA here — otherwise the round-trip
      # to set-creation would deny them post-write. If the CTA keyed off can_connect_repo
      # alone (the old bug), this test goes red.
      doc = render_empty(variant: :no_set, can_manage_sets: false, can_connect_repo: true, project_has_repository: false)
      expect(doc.text).to include(setup_hint)
      expect(doc.text).not_to include(connect_repo_label)
    end

    it 'falls to the neutral hint when the user may manage sets but NOT connect' do
      doc = render_empty(variant: :no_set, can_manage_sets: true, can_connect_repo: false, project_has_repository: false)
      expect(doc.text).to include(setup_hint)
      expect(doc.text).not_to include(connect_repo_label)
      expect(doc.text).not_to include(create_set_label)
    end
  end

  describe ':no_set WITH a repo — the CTA keys off can_manage_sets' do
    it 'shows the set-creation CTA (not the repo-connect CTA) once a repo exists' do
      doc = render_empty(variant: :no_set, can_manage_sets: true, can_connect_repo: true, project_has_repository: true)
      expect(doc.text).to include(create_set_label)
      expect(doc.text).not_to include(connect_repo_label)
    end
  end

  # The plain-language "what documentation is / is not" explainer is an onboarding
  # aid: it belongs ONLY next to the very first "nothing connected yet" state, never
  # over an empty search result or an already-connected-but-empty set. It is content,
  # not permission-gated — every :no_set viewer sees it regardless of the two flags.
  describe 'plain-language explainer' do
    let(:explainer_title) { I18n.t('views.organisations.documentation.empty.explainer.title') }
    let(:explainer_not_title) { I18n.t('views.organisations.documentation.empty.explainer.not_title') }
    let(:explainer_source) { I18n.t('views.organisations.documentation.empty.explainer.point_source') }

    it 'renders in the :no_set state independent of the permission flags' do
      doc = render_empty(variant: :no_set, can_manage_sets: false, can_connect_repo: false, project_has_repository: false)
      expect(doc.text).to include(explainer_title)
      expect(doc.text).to include(explainer_source)
      expect(doc.text).to include(explainer_not_title)
    end

    it 'is absent for :no_pages (a set exists — no onboarding needed)' do
      doc = render_empty(variant: :no_pages, can_manage_sets: true, can_connect_repo: true, project_has_repository: true)
      expect(doc.text).not_to include(explainer_title)
    end

    it 'is absent for :no_results (empty search, not an onboarding surface)' do
      doc = render_empty(variant: :no_results, can_manage_sets: true, can_connect_repo: true, project_has_repository: true)
      expect(doc.text).not_to include(explainer_title)
    end
  end
end
