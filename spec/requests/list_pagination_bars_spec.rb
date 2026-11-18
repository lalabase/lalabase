# frozen_string_literal: true

require 'rails_helper'

# What:  The pagination bar of the lists that had none worth the name.
# Type:  Request spec.
# Why:   Until 18.11.2026 four views printed the bar of a pagination gem the
#        application had no stylesheet for: the member activities and the admin
#        mail log showed "<12345678910>", glued together, the current page not
#        marked. And on three lists the page size named in the controller was an
#        option that gem ignored, so the "entries per page" select of the project
#        activities and of the saved views changed nothing.
RSpec.describe 'Pagination bars', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  def hrefs
    Nokogiri::HTML(response.body).css('a[href]').map { |link| link['href'] }
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

      it 'shows no bar for a list that fits on one page' do
        visit_list(items: 50)

        expect(response.body).not_to include('pagination-container-compact')
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
    end

    describe 'saved views' do
      before { create_list(:smart_folder, 7, organisation: organisation, project: project, user: user) }

      it 'takes the page size its select asks for' do
        get organisation_smart_folders_path(organisation, items: 5)

        expect(assigns(:smart_folders).size).to eq(5)
        expect(assigns(:pagy)).to have_attributes(count: 7, pages: 2)
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

    it 'shows no bar for a list that fits on one page' do
      get admin_email_logs_path(status: 'failed')

      expect(response).to have_http_status(:ok)
      expect(bar).to be_nil
    end
  end
end
