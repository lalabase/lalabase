# frozen_string_literal: true

require 'rails_helper'

# What:  The pagination bar of the lists that had none worth the name.
# Type:  Request spec.
# Why:   Until 18.11.2026 four views printed the bar of a pagination gem the
#        application had no stylesheet for: the member activities and the admin
#        mail log showed "<12345678910>", glued together, the current page not
#        marked. And on three lists the page size named in the controller was an
#        option that gem ignored, so the "entries per page" select of the project
#        activities and of the saved views changed nothing; on the results of a
#        saved view it changed nothing until 19.11.2026, because that page read
#        `?per_page=` only. A page behind the end of a list of one page showed no
#        bar at all, and with it no way back.
RSpec.describe 'Pagination bars', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  def hrefs
    Nokogiri::HTML(response.body).css('a[href]').map { |link| link['href'] }
  end

  # The query of every link on the page, as a Hash.
  def page_queries
    hrefs.map { |href| Rack::Utils.parse_nested_query(URI(href).query.to_s) }
  end

  describe 'in the application' do
    let(:project) { create(:project, organisation: organisation) }

    before do
      Prosopite.pause
      ActsAsTenant.current_tenant = organisation
      create(:membership, user: user, organisation: organisation, role: create(:admin_role, organisation: organisation))
      sign_in user
    end

    after do
      ActsAsTenant.current_tenant = nil
      Prosopite.resume
    end

    describe 'member activities' do
      before { create_list(:user_activity, 45, user: user, organisation: organisation) }

      def visit_list(params = {})
        get organisation_user_activities_path(organisation, { user_id: user.id }.merge(params))
      end

      it 'pages by the size every list starts with and says where the reader is' do
        visit_list

        expect(assigns(:activities).size).to eq(Pageable::DEFAULT_PER_PAGE)
        expect(response.body).to include('pagination-container-compact')
        expect(response.body).to include(I18n.t('views.shared.pagination_compact.page_of', page: 1, total: 3))
        expect(response.body).not_to include('class="pagy')
      end

      it 'shows other rows on the second page, and the rest on the last' do
        visit_list
        first = assigns(:activities).map(&:id)
        visit_list(page: 2)
        second = assigns(:activities).map(&:id)
        visit_list(page: 3)

        expect(first & second).to be_empty
        expect(assigns(:activities).size).to eq(5)
      end

      it 'keeps the member and the filter in the link to the next page' do
        visit_list(category: UserActivity::CATEGORIES[:auth])

        next_page = hrefs.map { |href| Rack::Utils.parse_nested_query(URI(href).query.to_s) }.find { |query| query['page'] == '2' }
        expect(next_page).to include('user_id' => user.id, 'category' => UserActivity::CATEGORIES[:auth])
      end

      it 'takes the page size the select asks for' do
        visit_list(items: 10)

        expect(assigns(:activities).size).to eq(10)
        expect(assigns(:pagy).pages).to eq(5)
      end

      it 'marks the size the page was cut by in its select, also when it is the saved one' do
        user.preference_store.set_items_per_page(10)

        visit_list

        selected = Nokogiri::HTML(response.body).at_css('.pagination-container-compact select option[selected]')
        expect(selected&.text&.squish).to eq('10')
      end

      # `?items=abc` paged by one row until 19.11.2026, while the select marked
      # no option and nothing was saved.
      it 'reads a page size that names no number as none' do
        visit_list(items: 'abc')

        expect(assigns(:pagy).limit).to eq(Pageable::DEFAULT_PER_PAGE)
      end

      it 'links back from a page behind the end, also of a list of one page' do
        visit_list(items: 50, page: 2)

        expect(assigns(:activities)).to be_empty
        expect(page_queries).to include(a_hash_including('page' => '1', 'items' => '50'))
      end

      it 'names its bar in English on an English page' do
        user.update!(language_preference: 'en')

        visit_list

        expect(response.body).to include('Page 1 of 3')
        expect(Nokogiri::HTML(response.body).at_css('.pagination-container-compact nav')['aria-label']).to eq('Pagination')
      end

      # The select sits in the bar, and the size it saves is the reader's for every
      # list. A bar that left with the second page took the way back with it.
      it 'keeps the bar and its page-size select when the list fits on one page' do
        visit_list(items: 50)

        expect(assigns(:pagy).pages).to eq(1)
        expect(response.body).to include('pagination-container-compact')
        options = Nokogiri::HTML(response.body).css('.pagination-container-compact select option')
        expect(options.map { |option| Rack::Utils.parse_query(URI(option['value']).query)['items'] }).to include('10', '20')
      end
    end

    describe 'project activities' do
      before do
        12.times do |i|
          create(:activity, trackable: project, organisation: organisation, actor: user,
                            key: 'project.note_created', action: 'note_created', parameters: { 'note_title' => "Notiz #{i}" })
        end
      end

      it 'takes the page size its select asks for' do
        get organisation_project_activities_path(organisation, project, items: 5)

        expect(assigns(:activities).size).to eq(5)
        expect(assigns(:pagy).pages).to eq(3)
      end

      it 'links the pages of the bar and keeps the page size in them' do
        get organisation_project_activities_path(organisation, project, items: 5)

        queries = hrefs.map { |href| Rack::Utils.parse_nested_query(URI(href).query.to_s) }
        expect(queries).to include('items' => '5', 'page' => '2')
        expect(queries).to include('items' => '5', 'page' => '3')
      end

      it 'names its bar in the language of the page' do
        get organisation_project_activities_path(organisation, project, items: 5)

        labels = Nokogiri::HTML(response.body).css('.pagination-container nav').map { |nav| nav['aria-label'] }
        expect(labels).to eq([I18n.t('views.shared.pagination.label', locale: :de)])
      end

      # The concrete words, not "differs from German": a missing key falls back
      # to German (config/initializers/i18n.rb), and a key printed as itself
      # differs as well.
      it 'names its bar in English on an English page' do
        user.update!(language_preference: 'en')

        get organisation_project_activities_path(organisation, project, items: 5)

        labels = Nokogiri::HTML(response.body).css('.pagination-container nav').map { |nav| nav['aria-label'] }
        expect(labels).to eq(['Pagination'])
        expect(response.body).to include('1 – 5 of 12', '5 entries')
      end

      it 'keeps the bar and its page-size select when the list fits on one page' do
        get organisation_project_activities_path(organisation, project, items: 50)

        expect(assigns(:pagy).pages).to eq(1)
        selected = Nokogiri::HTML(response.body).at_css('.pagination-container select option[selected]')
        expect(selected&.text&.squish).to eq(I18n.t('views.shared.pagination.entries', count: 50))
      end

      # A list behind the end has a page of its own in the bar: the last one.
      it 'links back from a page behind the end, also of a list of one page' do
        get organisation_project_activities_path(organisation, project, items: 50, page: 3)

        expect(assigns(:activities)).to be_empty
        expect(page_queries).to include(a_hash_including('page' => '1', 'items' => '50'))
      end

      # Stored without a ceiling until 18.11.2026; a full page load reads it
      # without an `?items=` that would have been clamped.
      it 'never pages by more than the ceiling, whatever the reader saved' do
        user.preference_store.set_items_per_page(1_000_000)

        get organisation_project_activities_path(organisation, project)

        expect(assigns(:pagy).limit).to eq(Pageable::MAX_PER_PAGE)
      end

      it 'saves a page size the address names at most at the ceiling' do
        get organisation_project_activities_path(organisation, project, items: 1_000_000)

        expect(user.reload.items_per_page_preference).to eq(Pageable::MAX_PER_PAGE)
      end
    end

    describe 'saved views' do
      before { create_list(:smart_folder, 7, organisation: organisation, project: project, user: user) }

      it 'takes the page size its select asks for' do
        get organisation_smart_folders_path(organisation, items: 5)

        expect(assigns(:smart_folders).size).to eq(5)
        expect(assigns(:pagy)).to have_attributes(count: 7, pages: 2)
      end

      # The JSON answer serialised the gem's object until 18.11.2026.
      it 'keeps the names of the numbers in its JSON answer' do
        get organisation_smart_folders_path(organisation, items: 5, format: :json)

        expect(response.parsed_body['pagination']).to include('count' => 7, 'page' => 1, 'last' => 2, 'in' => 5, 'offset' => 0)
      end

      it 'keeps the bar and its select when every view fits on one page' do
        get organisation_smart_folders_path(organisation, items: 10)

        expect(assigns(:pagy).pages).to eq(1)
        selected = Nokogiri::HTML(response.body).at_css('.pagination-container select option[selected]')
        expect(selected&.text&.squish).to eq(I18n.t('views.shared.pagination.entries', count: 10))
      end

      # Until 19.11.2026 the page asked for the rows of THIS page, found none and
      # offered to create the first saved view, with no way back.
      it 'links back from a page behind the end instead of saying there are no views' do
        get organisation_smart_folders_path(organisation, items: 5, page: 9)

        expect(response).to have_http_status(:ok)
        expect(assigns(:smart_folders)).to be_empty
        expect(response.body).not_to include(I18n.t('smart_folders.create_first', default: 'Erstellen Sie Ihren ersten Intelligenten Ordner'))
        expect(page_queries).to include(a_hash_including('page' => '2', 'items' => '5'))
      end
    end

    describe 'tags' do
      before { 3.times { |index| create(:tag, organisation: organisation, name: "tag-#{index}") } }

      def sort_queries
        Nokogiri::HTML(response.body).css('th a').map { |link| Rack::Utils.parse_nested_query(URI(link['href']).query.to_s) }
      end

      # The list answered 500 until 19.11.2026: its sort header built the address
      # through url_for with the path parameters.
      it 'links each sortable column to this list and keeps the search' do
        get organisation_tags_path(organisation, search: 'tag')

        expect(response).to have_http_status(:ok)
        expect(sort_queries).to include(a_hash_including('sort' => a_hash_including('column' => 'name'), 'search' => 'tag'))
        expect(sort_queries.map { |query| query.dig('sort', 'column') }).to include('name', 'created_at', 'updated_at')
      end

      it 'shows the compact bar and pages by its select' do
        get organisation_tags_path(organisation, items: 2)

        expect(assigns(:tags).size).to eq(2)
        expect(response.body).to include('pagination-container-compact')
        expect(page_queries).to include(a_hash_including('page' => '2', 'items' => '2'))
      end
    end

    describe 'the results of a saved view' do
      let(:folder) do
        create(:smart_folder, organisation: organisation, project: project, user: user, target_object_type: 'Note').tap do |view|
          group = create(:smart_folder_rule_group, smart_folder: view)
          create(:smart_folder_rule, smart_folder_rule_group: group, field: 'title', operator: 'contains', value: 'Cap')
        end
      end

      before { 30.times { |i| create(:note, title: "Cap Note #{i}", project: project, organisation: organisation, creator: user) } }

      def selected_size
        Nokogiri::HTML(response.body).at_css('.pagination-container select option[selected]')&.text&.squish
      end

      it 'takes the page size its select asks for and marks it' do
        get organisation_smart_folder_path(organisation, folder, items: 10)

        expect(assigns(:items).size).to eq(10)
        expect(assigns(:results_pagy)).to have_attributes(count: 30, limit: 10, pages: 3)
        expect(selected_size).to eq(I18n.t('views.shared.pagination.entries', count: 10))
      end

      it 'pages by the size the reader saved, as every list does' do
        user.preference_store.set_items_per_page(5)

        get organisation_smart_folder_path(organisation, folder)

        expect(assigns(:items).size).to eq(5)
        expect(selected_size).to eq(I18n.t('views.shared.pagination.entries', count: 5))
      end

      # The select sends `?items=` and the page links keep the query, so an
      # address that names both takes the select's.
      it 'prefers the size of the select over a per_page of the address' do
        get organisation_smart_folder_path(organisation, folder, per_page: 3, items: 20)

        expect(assigns(:items).size).to eq(20)
      end

      it 'keeps the bar and its select when every result fits on one page' do
        get organisation_smart_folder_path(organisation, folder, items: 50)

        expect(assigns(:results_pagy).pages).to eq(1)
        expect(selected_size).to eq(I18n.t('views.shared.pagination.entries', count: 50))
      end

      it 'links back from a page behind the end instead of saying there are no results' do
        get organisation_smart_folder_path(organisation, folder, items: 10, page: 9)

        expect(assigns(:items)).to be_empty
        expect(response.body).not_to include(I18n.t('smart_folders.no_results'))
        expect(page_queries).to include(a_hash_including('page' => '3', 'items' => '10'))
      end
    end
  end

  describe 'the admin mail log' do
    before do
      ActsAsTenant.with_tenant(organisation) do
        notification = create(:notification, organisation: organisation, recipient: user)
        30.times { create(:email_log, organisation: organisation, notification: notification, status: 'sent') }
        create(:email_log, organisation: organisation, notification: notification, status: 'failed')
      end
      beuser = create(:beuser)
      post admin_log_in_path, params: { email: beuser.email, password: beuser.password }
    end

    # A method, not a let: one example reads the bar of two answers.
    def bar
      Nokogiri::HTML(response.body).at_css(%(nav[aria-label="#{I18n.t('admin.common.pagination.label')}"]))
    end

    it 'shows 25 rows and says where the reader is' do
      get admin_email_logs_path

      expect(assigns(:email_logs).size).to eq(Admin::EmailLogsController::LOGS_PER_PAGE)
      expect(bar.text.squish).to include(I18n.t('admin.common.pagination.page_of', page: 1, total: 2))
      expect(response.body).not_to include('class="pagy')
    end

    it 'offers only the way forward on the first page and only the way back on the last' do
      get admin_email_logs_path
      expect(bar.css('a').map { |link| link.text.strip }).to eq([I18n.t('admin.common.pagination.next')])

      get admin_email_logs_path(page: 2)
      expect(bar.css('a').map { |link| link.text.strip }).to eq([I18n.t('admin.common.pagination.previous')])
      expect(assigns(:email_logs).size).to eq(6)
    end

    it 'keeps the filter in the link to the next page' do
      get admin_email_logs_path(status: 'sent')

      expect(bar.at_css('a')['href']).to eq('/admin/email_logs?page=2&status=sent')
    end

    it 'shows no bar for a list that fits on one page, and no empty box for it' do
      get admin_email_logs_path(status: 'failed')

      expect(response).to have_http_status(:ok)
      expect(bar).to be_nil
      expect(response.body).not_to include('bg-white px-4 py-3 border-t border-gray-200 sm:px-6')
    end

    # A bookmarked `?page=2` of a list that shrank to one page.
    it 'links back from a page behind the end of a list of one page' do
      get admin_email_logs_path(status: 'failed', page: 2)

      expect(assigns(:email_logs)).to be_empty
      expect(bar.css('a').map { |link| [link.text.strip, link['href']] })
        .to eq([[I18n.t('admin.common.pagination.previous'), '/admin/email_logs?page=1&status=failed']])
    end

    # The gem's limit extra read `?limit=`, up to 100.
    it 'takes another page size from the address, up to its ceiling' do
      get admin_email_logs_path(limit: 10)
      expect(assigns(:email_logs).size).to eq(10)

      get admin_email_logs_path(limit: 1000)
      expect(assigns(:pagy).limit).to eq(Admin::EmailLogsController::MAX_LOGS_PER_PAGE)
    end
  end
end
