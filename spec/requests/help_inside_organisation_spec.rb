# frozen_string_literal: true

require 'rails_helper'

# What: A full help page (/hilfe/<slug>, /hilfe/search) opened from inside an
#       organisation renders the whole application layout, and with it the
#       global search overlay and its project select.
# Type: Request spec, regression guard for a production 500 (10.09.2026).
# Why:  HelpController sits OUTSIDE Organisations::BaseController, yet it
#       restores the session organisation (set_optional_organisation) so the
#       sidebar stays full. That opens global_search_available?, and the search
#       form in the layout asks for selectable_projects. The method used to
#       reach every view through TimeSessionsHelper as an unscoped fallback
#       (Project.order(:name)); #675 deleted that helper and every full help
#       page raised NameError. The owner now sits on ApplicationController,
#       next to the gate that decides whether the overlay renders at all.
#
#       The contextual-help drawer never broke: its turbo-frame fetch gets the
#       slim frame layout, which carries no overlay. That is why these examples
#       request the FULL page.
#
#       Two conditions make the bug visible, and help_spec's "Org-Shell" example
#       meets only the first, which is why it stayed green:
#       1. an organisation in the SESSION, reached here the way a user reaches
#          it (visit an org page first), because a request spec cannot write
#          the session directly;
#       2. a member who may READ at least one project, otherwise the search
#          gate stays shut and the form never renders.
RSpec.describe 'Help inside an organisation', type: :request do
  let(:organisation) { create(:organisation) }
  let(:role) do
    create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}", is_default: true)
  end
  let(:member) do
    u = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: u, organisation: organisation, role: role, active: true)
    end
    u
  end
  let(:readable_project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Readable Project') }
  end
  let(:hidden_project) do
    ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation, name: 'Hidden Project') }
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:project_permission, user: member, project: readable_project, tickets_access: 'read_only')
    hidden_project
    sign_in member
    # Entering an org page writes session[:current_organisation_id], the only
    # place HelpController looks for the organisation.
    get organisation_root_path(organisation_id: organisation.id)
  end

  def search_project_options
    Nokogiri::HTML(response.body)
            .css('[data-search-overlay-target="overlay"] select[name="project_id"] option')
            .map(&:text)
  end

  describe 'GET /hilfe/<slug>' do
    before { get help_page_path(slug: 'guides/basics/erste-seite') }

    it 'renders the page with the search overlay' do
      expect(response).to have_http_status(:ok)
      expect(response.body.scan('data-search-overlay-target="overlay"').size).to eq(1)
    end

    # The fallback #675 removed listed EVERY project of the organisation. A fix
    # that brings back an unscoped list turns this page green again and leaks
    # project names, so the select is pinned in both directions.
    it 'offers only the projects the member may read' do
      expect(search_project_options).to include('Readable Project')
      expect(search_project_options).not_to include('Hidden Project')
    end
  end

  describe 'GET /hilfe/search' do
    it 'renders the results page with the search overlay' do
      get help_search_path(q: 'ticket')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-search-overlay-target="overlay"')
    end
  end
end
