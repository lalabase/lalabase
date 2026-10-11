# frozen_string_literal: true

require 'rails_helper'

# What: the help on an instance that does not carry the handbook.
#
# Why:  that is every self-hosted instance, by decision: the documentation is
#       not part of the open source core (doc/docs_delivery_plan.md, goal 1).
#       So this is a NORMAL state, not an error, and what makes it acceptable is
#       that the links work and point at the real, online handbook. A generic
#       "unavailable" screen would not be the same thing.
RSpec.describe 'Help without a catalogue', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation, active: true)
    sign_in user
  end

  it 'answers the help index with a pointer at the public documentation' do
    without_docs_catalogue do
      get help_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('https://lalabase.com/docs/de')
      expect(response.body).to include(I18n.t('views.organisations.help.unavailable.title'))
    end
  end

  it 'answers a page address the same way, instead of 404 or 500' do
    without_docs_catalogue do
      get help_page_path(slug: 'guides/basics/first-project')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('https://lalabase.com/docs/de')
    end
  end

  it 'carries the drawer frame, so the contextual drawer grafts this and not Turbo English' do
    # Without a matching frame Turbo puts its untranslated "Content missing"
    # into the drawer, which is the failure this whole view exists to avoid.
    without_docs_catalogue do
      get help_page_path(slug: 'guides/basics/first-project'),
          headers: { 'Turbo-Frame' => 'contextual_help_content' }

      expect(response.body).to include('contextual_help_content')
      # And WITHOUT the app shell around it: a frame request that renders the
      # whole layout still contains the frame, so the assertion above alone
      # stayed green when the layout switch was reverted.
      expect(response.body).not_to include('<html')
    end
  end

  it 'leaves the search quiet rather than erroring' do
    without_docs_catalogue do
      get help_search_path, params: { q: 'Projekt' }

      expect(response).to have_http_status(:ok)
    end
  end

  it 'sends the reader to the public documentation from the app header' do
    without_docs_catalogue do
      get help_path

      # Scoped to the header's own link: the page body carries the same href, so
      # an unscoped match stayed green with the header link reverted.
      header_link = response.body[/<a[^>]*title="#{Regexp.escape(I18n.t('navigation.help'))}"[^>]*>/]
      expect(header_link).to be_present
      expect(header_link).to include('href="https://lalabase.com/docs/de"')
    end
  end

  describe 'the contextual help question' do
    it 'links into the public documentation instead of opening a drawer onto nothing' do
      # The menu renders wherever a page declares a context; the account form is
      # one, and it is reachable without an organisation.
      without_docs_catalogue do
        get edit_user_registration_path

        question = response.body[%r{<a[^>]*https://lalabase\.com/docs/de/guides[^>]*>}]
        expect(question).to be_present
        expect(question).not_to include('contextual-help-drawer#open')
      end
    end

    it 'opens the drawer when the handbook is here, for contrast' do
      get edit_user_registration_path

      expect(response.body).to include('contextual-help-drawer#open')
      expect(response.body).not_to include('https://lalabase.com/docs/de/guides')
    end
  end

  describe 'with a catalogue, for contrast' do
    it 'keeps the help local and says nothing about the public documentation' do
      get help_path

      expect(response).to have_http_status(:found).or have_http_status(:ok)
      expect(response.body).not_to include(I18n.t('views.organisations.help.unavailable.title'))
    end
  end
end
