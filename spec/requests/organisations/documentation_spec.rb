# frozen_string_literal: true

require 'rails_helper'

# What: The documentation browsing area end-to-end — the :documentation area
#       gate (T6 security), read rendering, and write-gated manual sync.
# Type: Request spec.
# Why:  Without the read gate a user with no :documentation right could browse
#       synced docs; without the write gate any reader could trigger syncs.
RSpec.describe 'Organisations::Documentation', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:repository) { create(:project_repository, project: project, organisation: organisation) }
  let(:documentation_set) { create(:documentation_set, project: project, project_repository: repository) }

  let(:reader_role) do
    role = create(:role, organisation: organisation, title: 'doc_reader')
    create(:project_read_permission, role: role, area: 'documentation')
    role
  end
  let(:writer_role) do
    role = create(:role, organisation: organisation, title: 'doc_writer')
    create(:project_write_permission, role: role, area: 'documentation')
    role
  end
  let(:no_access_role) { create(:role, organisation: organisation, title: 'no_access') }

  let(:index_path) { organisation_project_documentation_index_path(organisation, project) }

  before { ActsAsTenant.current_tenant = organisation }

  def sign_in_with_role(role)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    sign_in user
  end

  describe 'authentication' do
    it 'redirects an anonymous visitor to sign in' do
      get index_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'the :documentation read gate (T6)' do
    it 'blocks a user without documentation access' do
      documentation_set # ensure a set exists to rule out an empty-state 200
      sign_in_with_role(no_access_role)

      get index_path

      expect(response).to redirect_to(organisation_project_path(organisation, project))
      expect(flash[:alert]).to eq(I18n.t('flash.shared.not_authorized'))
    end

    it 'allows a user with documentation read access' do
      create(:documentation_page, documentation_set: documentation_set, path: 'intro.md', title: 'Intro')
      sign_in_with_role(reader_role)

      get index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Intro')
    end
  end

  describe 'browsing (read user)' do
    before { sign_in_with_role(reader_role) }

    # The sidebar search no longer filters the tree (it shows a separate live
    # result list, mirroring /hilfe) — the tree always stays whole.
    it 'keeps the full page tree regardless of the q parameter' do
      create(:documentation_page, documentation_set: documentation_set, path: 'alpha.md', title: 'Alpha Guide')
      create(:documentation_page, documentation_set: documentation_set, path: 'beta.md', title: 'Beta Notes')

      get index_path, params: { q: 'Alpha' }

      expect(response.body).to include('Alpha Guide')
      expect(response.body).to include('Beta Notes')
    end

    it 'renders the page body plain and exposes the client-side highlight hook' do
      create(:documentation_page, documentation_set: documentation_set, path: 'a.md',
                                  title: 'Einstellungen', markdown_body: 'Die Grundlage der Bewertung.',
                                  rendered_html: '<p>Die Grundlage der Bewertung.</p>')

      get index_path, params: { q: 'Grundlage' }

      # Highlighting is client-side now (frame-search#highlightContent): the body is
      # rendered plain (no server <mark>), and the sidebar exposes the prose selector
      # plus the pre-filled query the controller needs to highlight live.
      expect(response.body).to include('Die Grundlage der Bewertung.')
      expect(response.body).not_to include('doc-search-hit')
      expect(response.body).to include('data-frame-search-highlight-selector-value=".doc-prose"')
      expect(response.body).to include('value="Grundlage"')
    end

    it 'rebuilds the sidebar result list on a q-carrying visit (suggestions survive the click)' do
      create(:documentation_page, documentation_set: documentation_set, path: 'intro.md',
                                  title: 'Grundlagen-Seite', markdown_body: 'Die Grundlage.',
                                  rendered_html: '<p>Die Grundlage.</p>')

      get index_path, params: { q: 'Grundlage', page: 'intro.md' }

      # The result frame is pre-rendered from ?q=, so the suggestions survive the
      # click. A result link carries q= (distinct from the q-less tree links), and
      # the group is labelled with the hit count so it reads as search results.
      expect(response.body).to include('q=Grundlage')
      expect(response.body).to include('Grundlagen-Seite')
      expect(response.body).to include(I18n.t('views.organisations.documentation.index.results_count', count: 1))
    end

    it 'renders no pre-filled result list without a query' do
      create(:documentation_page, documentation_set: documentation_set, path: 'a.md', title: 'Alpha')

      get index_path

      # No result links (which carry q=) exist when nothing was searched.
      expect(response.body).not_to include('q=')
    end

    it 'renders the content of the page named by the page parameter' do
      create(:documentation_page, documentation_set: documentation_set, path: 'a.md',
                                  title: 'Page A', rendered_html: '<p>Body of A</p>')
      create(:documentation_page, documentation_set: documentation_set, path: 'b.md',
                                  title: 'Page B', rendered_html: '<p>Body of B</p>')

      get index_path, params: { page: 'b.md' }

      expect(response.body).to include('Body of B')
    end

    it 'falls back to the first set for an unknown set_id instead of erroring' do
      create(:documentation_page, documentation_set: documentation_set, path: 'intro.md', title: 'Intro')

      get index_path, params: { set_id: SecureRandom.uuid }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Intro')
    end

    it 'falls back to the first page for a bogus page param instead of erroring' do
      create(:documentation_page, documentation_set: documentation_set, path: 'a.md',
                                  title: 'Page A', rendered_html: '<p>Body of A</p>')

      # Traversal-shaped input must neither 500 nor select anything outside the set.
      get index_path, params: { page: '../../etc/passwd' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Body of A')
    end

    it 'shows the specific error banner while the set is failed (DT4)' do
      documentation_set.update!(sync_status: 'failed')
      create(:documentation_sync_run, documentation_set: documentation_set,
                                      status: 'failed', error_class: 'auth')

      get index_path

      expect(response.body).to include(I18n.t('views.organisations.documentation.sync_error.auth'))
    end

    # DT5 end-to-end: visit records a marker; a later edit surfaces the
    # "changed since last visit" flag on the next visit.
    it 'flags a page changed since the last visit' do
      page = create(:documentation_page, documentation_set: documentation_set, path: 'a.md', title: 'Page A')

      get index_path # first visit records last_viewed_at
      # update_columns on purpose: we must force updated_at PAST the visit marker;
      # the normal timestamp callback would reset it to now and defeat the test.
      page.update_columns(markdown_body: 'edited', updated_at: 1.hour.from_now)
      get index_path # second visit computes "changed" against the first marker

      expect(response.body).to include(I18n.t('views.organisations.documentation.index.changed_since_visit'))
    end

    # The other half of the DT5 block: the visit must REFRESH the marker, so an
    # already-seen change stops being flagged on the next visit.
    it 'clears the changed flag once the user has seen the change' do
      page = create(:documentation_page, documentation_set: documentation_set, path: 'a.md', title: 'Page A')

      get index_path # visit 1: marker set
      page.update_columns(markdown_body: 'edited', updated_at: Time.current)
      get index_path # visit 2: change flagged AND marker refreshed past updated_at
      expect(response.body).to include(I18n.t('views.organisations.documentation.index.changed_since_visit'))

      get index_path # visit 3: nothing changed since visit 2

      expect(response.body).not_to include(I18n.t('views.organisations.documentation.index.changed_since_visit'))
    end

    it 'shows the pages of the set selected via set_id, not the first set' do
      create(:documentation_page, documentation_set: documentation_set, path: 'a.md', title: 'First Set Page')
      second_set = create(:documentation_set, project: project, name: 'Zweites Set')
      create(:documentation_page, documentation_set: second_set, path: 'b.md', title: 'Second Set Page')

      get index_path, params: { set_id: second_set.id }

      expect(response.body).to include('Second Set Page')
      expect(response.body).not_to include('First Set Page')
    end

    # DT7: the mobile variant is its own rendering branch (tree OR page).
    describe 'mobile viewport' do
      it 'shows the back-to-tree link when a page is open' do
        create(:documentation_page, documentation_set: documentation_set, path: 'a.md',
                                    title: 'Page A', rendered_html: '<p>Body of A</p>')

        get index_path, params: { viewport: 'mobile', page: 'a.md' }

        expect(response.body).to include(I18n.t('views.organisations.documentation.index.back_to_tree'))
        expect(response.body).to include('Body of A')
      end

      it 'shows only the tree (no page body) when no page is open' do
        create(:documentation_page, documentation_set: documentation_set, path: 'a.md',
                                    title: 'Page A', rendered_html: '<p>Body of A</p>')

        get index_path, params: { viewport: 'mobile' }

        expect(response.body).to include('Page A')
        expect(response.body).not_to include('Body of A')
      end
    end
  end

  # The sidebar live search (mirrors /hilfe): a Turbo-frame result list, read-gated
  # and scoped to the selected set. Result links carry q= so the opened page
  # highlights the hit.
  describe 'live search (GET :search)' do
    let(:search_path) { search_organisation_project_documentation_index_path(organisation, project) }
    let(:frame_headers) { { 'Turbo-Frame' => 'documentation-search-results' } }

    it 'blocks a user without documentation access' do
      sign_in_with_role(no_access_role)

      get search_path, params: { q: 'Alpha', set_id: documentation_set.id }

      expect(response).to redirect_to(organisation_project_path(organisation, project))
    end

    context 'as a read user' do
      before { sign_in_with_role(reader_role) }

      it 'returns matching pages as result links that carry the query' do
        create(:documentation_page, documentation_set: documentation_set, path: 'guide/alpha.md',
                                    title: 'Alpha Guide', markdown_body: 'about Grundlage topics')
        create(:documentation_page, documentation_set: documentation_set, path: 'beta.md', title: 'Beta Notes')

        get search_path, params: { q: 'Grundlage', set_id: documentation_set.id }, headers: frame_headers

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Alpha Guide')
        expect(response.body).not_to include('Beta Notes')
        # The link opens the page AND keeps q= so the body highlight fires.
        expect(response.body).to include('page=guide%2Falpha.md')
        expect(response.body).to include('q=Grundlage')
      end

      it 'shows the empty message when nothing matches' do
        create(:documentation_page, documentation_set: documentation_set, path: 'a.md', title: 'Page A')

        get search_path, params: { q: 'Zzzznope', set_id: documentation_set.id }, headers: frame_headers

        expect(response.body).to include(I18n.t('views.organisations.documentation.index.search_empty'))
      end

      it 'stays empty (no result list, no empty message) below the minimum term length' do
        create(:documentation_page, documentation_set: documentation_set, path: 'a.md', title: 'Alpha')

        get search_path, params: { q: 'A', set_id: documentation_set.id }, headers: frame_headers

        expect(response.body).not_to include('Alpha')
        expect(response.body).not_to include(I18n.t('views.organisations.documentation.index.search_empty'))
      end

      it 'scopes results to the set named by set_id' do
        create(:documentation_page, documentation_set: documentation_set, path: 'a.md',
                                    title: 'First Set Page', markdown_body: 'shared keyword')
        second_set = create(:documentation_set, project: project, name: 'Zweites Set')
        create(:documentation_page, documentation_set: second_set, path: 'b.md',
                                    title: 'Second Set Page', markdown_body: 'shared keyword')

        get search_path, params: { q: 'keyword', set_id: second_set.id }, headers: frame_headers

        expect(response.body).to include('Second Set Page')
        expect(response.body).not_to include('First Set Page')
      end
    end
  end

  # Logbook (Slice 2): read-gated — readers may see the change history, users
  # without documentation access may not.
  describe 'history (logbook)' do
    let(:history_path) do
      history_organisation_project_documentation_set_path(organisation, project, documentation_set)
    end

    it 'shows commits and sync runs to a read user' do
      create(:documentation_commit, documentation_set: documentation_set,
                                    message: 'docs: neue Anleitung', author_name: 'Ada Lovelace')
      create(:documentation_sync_run, documentation_set: documentation_set,
                                      status: 'failed', trigger: 'polling', error_class: 'auth')
      sign_in_with_role(reader_role)

      get history_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('docs: neue Anleitung')
      expect(response.body).to include('Ada Lovelace')
      # The failed run surfaces its specific error, and polling is labelled.
      expect(response.body).to include(I18n.t('views.organisations.documentation.sync_error.auth'))
      expect(response.body).to include(I18n.t('views.organisations.documentation.history.trigger.polling'))
    end

    # The run says how many images it kept and how many it turned down: an image that is
    # too large or not an image shows as text on the page, and this is where a reader of
    # the logbook learns why.
    it 'says how many images a run kept and how many it did not show' do
      create(:documentation_sync_run, documentation_set: documentation_set, status: 'ready',
                                      trigger: 'manual', assets_synced: 12, assets_skipped: 2)
      sign_in_with_role(reader_role)

      get history_path

      expect(response.body).to include(I18n.t('views.organisations.documentation.history.run_assets', count: 12))
      expect(response.body).to include(I18n.t('views.organisations.documentation.history.run_assets_skipped', count: 2))
    end

    it 'says nothing about images for a run that met none' do
      create(:documentation_sync_run, documentation_set: documentation_set, status: 'ready', trigger: 'manual')
      sign_in_with_role(reader_role)

      get history_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t('views.organisations.documentation.history.run_assets', count: 0))
      expect(response.body).not_to include(I18n.t('views.organisations.documentation.history.run_assets_skipped', count: 0))
    end

    it 'blocks a user without documentation access' do
      sign_in_with_role(no_access_role)

      get history_path

      expect(response).to have_http_status(:redirect)
    end

    it 'links the logbook from the documentation index' do
      create(:documentation_page, documentation_set: documentation_set, path: 'a.md', title: 'Page A')
      sign_in_with_role(reader_role)

      get index_path

      expect(response.body).to include(history_path)
    end
  end

  # The write actions form one functional block: authorize → actor → redirect,
  # or re-render with errors. Each action gets its own negative test so a
  # dropped `authorize` in ONE action breaks exactly that action's test.
  describe 'set management (create/update/destroy)' do
    let(:create_path) { organisation_project_documentation_sets_path(organisation, project) }
    let(:update_path) { organisation_project_documentation_set_path(organisation, project, documentation_set) }

    # The request middleware resets the tenant after each request, so counts via
    # a `change` matcher would raise NoTenantSet — assert inside with_tenant.
    def find_set(name)
      ActsAsTenant.with_tenant(organisation) { DocumentationSet.find_by(name: name) }
    end

    context 'as a write user' do
      before { sign_in_with_role(writer_role) }

      it 'creates a set and lands on the documentation index with it selected' do
        post create_path, params: { documentation_set: {
          name: 'Handbuch', path_prefix: 'docs/', project_repository_id: repository.id
        } }

        new_set = find_set('Handbuch')
        expect(new_set).to be_present
        expect(new_set.project_repository_id).to eq(repository.id)
        expect(response).to redirect_to(
          organisation_project_documentation_index_path(organisation, project, set_id: new_set.id)
        )
      end

      it 're-renders the form with errors and repositories on invalid input' do
        post create_path, params: { documentation_set: {
          name: '', path_prefix: 'docs/', project_repository_id: repository.id
        } }

        expect(response).to have_http_status(:unprocessable_content)
        # The repo select must survive the re-render (regression: a forgotten
        # @repositories on the failure path crashes the form).
        expect(response.body).to include(repository.full_name)
      end

      it 'rejects a traversal path_prefix at the controller boundary' do
        post create_path, params: { documentation_set: {
          name: 'Böse', path_prefix: '../', project_repository_id: repository.id
        } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(find_set('Böse')).to be_nil
      end

      it 'updates a set' do
        patch update_path, params: { documentation_set: { name: 'Umbenannt' } }

        expect(find_set('Umbenannt')).to be_present
        expect(response).to redirect_to(
          organisation_project_documentation_index_path(organisation, project, set_id: documentation_set.id)
        )
      end

      it 'destroys a set' do
        name = documentation_set.name

        delete update_path

        expect(find_set(name)).to be_nil
        expect(response).to redirect_to(organisation_project_documentation_index_path(organisation, project))
      end
    end

    context 'as a read-only user' do
      before { sign_in_with_role(reader_role) }

      it 'blocks create' do
        post create_path, params: { documentation_set: {
          name: 'Verboten', path_prefix: 'docs/', project_repository_id: repository.id
        } }

        expect(find_set('Verboten')).to be_nil
        expect(response).to have_http_status(:redirect)
      end

      it 'blocks update' do
        patch update_path, params: { documentation_set: { name: 'Gehackt' } }

        expect(find_set('Gehackt')).to be_nil
        expect(response).to have_http_status(:redirect)
      end

      it 'blocks destroy' do
        name = documentation_set.name

        delete update_path

        expect(find_set(name)).to be_present
        expect(response).to have_http_status(:redirect)
      end
    end
  end

  describe 'management views render for a write user' do
    before { sign_in_with_role(writer_role) }

    it 'renders the empty state with a connect action when no set exists' do
      get index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.organisations.documentation.index.connect'))
    end

    it 'renders the new-set form' do
      repository # ensure a connectable repository exists

      get new_organisation_project_documentation_set_path(organisation, project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.organisations.documentation.form.save'))
    end

    it 'renders the edit-set form with a disconnect action' do
      get edit_organisation_project_documentation_set_path(organisation, project, documentation_set)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('views.organisations.documentation.edit.disconnect'))
    end
  end

  describe 'manual sync is write-gated' do
    let(:sync_path) do
      sync_organisation_project_documentation_set_path(organisation, project, documentation_set)
    end

    it 'forbids a read-only user from triggering a sync' do
      sign_in_with_role(reader_role)

      post sync_path

      # Blocked (redirected away) and, critically, no sync was triggered.
      expect(response).to have_http_status(:redirect)
      expect(documentation_set.reload.sync_status).to eq('never_synced')
    end

    it 'lets a write user trigger a sync' do
      allow(DocumentationSyncJob).to receive(:perform_later)
      sign_in_with_role(writer_role)

      post sync_path

      expect(response).to redirect_to(
        organisation_project_documentation_index_path(organisation, project, set_id: documentation_set.id)
      )
      expect(documentation_set.reload.sync_status).to eq('syncing')
    end

    it 'surfaces an actor failure as an alert instead of claiming success' do
      sign_in_with_role(writer_role)
      failure = instance_double(Actors::BaseActor::Result, success?: false, errors: ['Sync fehlgeschlagen'])
      allow(Actors::TriggerDocumentationSync).to receive(:call).and_return(failure)

      post sync_path

      expect(response).to redirect_to(
        organisation_project_documentation_index_path(organisation, project, set_id: documentation_set.id)
      )
      expect(flash[:alert]).to eq('Sync fehlgeschlagen')
      expect(flash[:notice]).to be_nil
    end
  end
end
