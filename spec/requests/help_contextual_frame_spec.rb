# frozen_string_literal: true

require 'rails_helper'

# What:  The contextual-help drawer foundation (doc/kontexthilfe_drawer_plan.md,
#        Slice A): the help page content is wrapped in the shared turbo-frame
#        "contextual_help_content" (D2) so the body-level drawer can graft it,
#        while a direct /hilfe visit keeps rendering the full page (tree, search,
#        frame inline) — and never carries a duplicate frame id.
# Type:  Request specs against HelpController and a regular app page (full stack).
# Why:   The drawer has no server endpoint of its own — this seam (one frame id,
#        rendered exactly once per page, prose inside it, help-scope styling
#        anchor present) is the entire contract between drawer and help surface.
#        The JS behaviour on top is covered by the system spec (Slice B).
RSpec.describe 'Contextual help drawer frame', type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:user) { create(:user) }
  let!(:membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: admin_role, active: true)
    end
  end

  # A page the recorded catalogue really holds. The recording is an example of
  # two invented pages rather than the handbook, because the handbook's text
  # must not live in this repository (doc/docs_delivery_plan.md, goal 1).
  let(:slug) { 'guides/basics/erste-seite' }

  before do
    ActsAsTenant.current_tenant = organisation
    sign_in user
  end

  after { ActsAsTenant.current_tenant = nil }

  def doc
    Nokogiri::HTML(response.body)
  end

  describe 'GET /hilfe/<slug> (direct visit, desktop)' do
    it 'renders the full page with the content frame inline — exactly once, no id collision' do
      get help_page_path(slug: slug)

      expect(response).to have_http_status(:ok)
      # Tree + search stay OUTSIDE the frame (regression: full page keeps its
      # chrome, and the drawer must never graft page chrome along with the prose).
      expect(response.body).to include(I18n.t('views.organisations.help.search.placeholder'))
      frames = doc.css('turbo-frame#contextual_help_content')
      expect(frames.size).to eq(1)
      expect(frames.first.to_html).not_to include(I18n.t('views.organisations.help.search.placeholder'))
      expect(frames.first.at_css('.help-prose')).to be_present
      # Links inside the inline frame must keep navigating the whole page.
      expect(frames.first[:target]).to eq('_top')
    end

    it 'carries the class-based prose-style scope on the page wrapper' do
      get help_page_path(slug: slug)

      expect(doc.at_css('#help-page')[:class]).to include('help-scope')
    end

    it 'does not render the body-level drawer on help pages (no duplicate frame id)' do
      get help_page_path(slug: slug)

      expect(response.body).not_to include('contextual-help-drawer-target="overlay"')
    end
  end

  describe 'GET /hilfe/<slug> (mobile branch)' do
    it 'wraps the page content in the same frame' do
      get help_page_path(slug: slug, viewport: 'mobile')

      expect(response).to have_http_status(:ok)
      frames = doc.css('turbo-frame#contextual_help_content')
      expect(frames.size).to eq(1)
      expect(frames.first.at_css('.help-prose')).to be_present
    end
  end

  describe 'GET /hilfe/<slug> as a turbo-frame request (what the drawer fetches)' do
    it 'responds with the frame and the prose content inside it — without the app shell' do
      get help_page_path(slug: slug), headers: { 'Turbo-Frame' => 'contextual_help_content' }

      expect(response).to have_http_status(:ok)
      frame = doc.at_css('turbo-frame#contextual_help_content')
      expect(frame).to be_present
      expect(frame.at_css('.help-prose')).to be_present
      # Turbo discards everything but the frame — rendering the full layout
      # (org sidebar incl. tenant queries) per drawer click is pure waste.
      expect(response.body).not_to include('<body')
    end

    it 'keeps the frame on a 404 so the drawer never hits turbo:frame-missing' do
      get help_page_path(slug: 'guides/gibt-es/nicht'), headers: { 'Turbo-Frame' => 'contextual_help_content' }

      expect(response).to have_http_status(:not_found)
      expect(doc.at_css('turbo-frame#contextual_help_content')).to be_present
    end
  end

  describe 'GET /hilfe/<unknown slug> (direct visit)' do
    it 'renders the app-styled 404 with the frame inline — exactly once' do
      get help_page_path(slug: 'guides/gibt-es/nicht')

      expect(response).to have_http_status(:not_found)
      expect(doc.css('turbo-frame#contextual_help_content').size).to eq(1)
    end
  end

  describe 'regular app page (drawer host)' do
    it 'renders the body-level drawer with the empty frame exactly once' do
      get organisation_time_sessions_path(organisation)

      expect(response).to have_http_status(:ok)
      expect(doc.css('turbo-frame#contextual_help_content').size).to eq(1)
      overlay = doc.at_css('[data-contextual-help-drawer-target="overlay"]')
      expect(overlay).to be_present
      # Dialog semantics sit on the PANEL (where focus lands), not the overlay.
      panel = doc.at_css('[data-contextual-help-drawer-target="panel"]')
      expect(panel[:role]).to eq('dialog')
      expect(panel['aria-labelledby']).to eq('contextual-help-drawer-title')
      # No src — the drawer controller sets it per clicked question.
      expect(doc.at_css('turbo-frame#contextual_help_content')[:src]).to be_nil
      # The drawer content wrapper carries the prose-style scope (help-scope).
      expect(doc.at_css('[data-contextual-help-drawer-target="overlay"] .help-scope')).to be_present
      # Escape hatch: the full-page link the controller re-points per question.
      expect(doc.at_css('[data-contextual-help-drawer-target="fullPageLink"]')).to be_present
    end

    it 'mounts the drawer controller on the body' do
      get organisation_time_sessions_path(organisation)

      expect(doc.at_css('body')['data-controller']).to include('contextual-help-drawer')
    end

    it 'renders the drawer host on org-free pages too (help works without an org)' do
      get edit_user_preferences_path

      expect(response).to have_http_status(:ok)
      expect(doc.css('turbo-frame#contextual_help_content').size).to eq(1)
    end
  end

  describe 'signed-out page' do
    it 'does not render the drawer for anonymous visitors' do
      sign_out user

      get new_user_session_path

      expect(response.body).not_to include('contextual-help-drawer-target="overlay"')
    end
  end
end
