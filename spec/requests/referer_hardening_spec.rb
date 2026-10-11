# frozen_string_literal: true

require 'rails_helper'

# Referer hardening (audit follow-up). The Referer header is user-controlled
# input; raw usage had two failure classes left after the time-sessions fixes:
#
# A) Raw referer REDIRECT: ApplicationController#user_not_authorized used
#    `redirect_to(request.referer || root_path)`. A cross-host Referer raises
#    ActionController::Redirecting::UnsafeRedirectError (-> 500) instead of
#    degrading to the fallback. Reachable on EVERY Pundit denial (global
#    rescue_from); exercised here via the org settings page as a plain member.
#
# B) Raw referer PARSING: the inbox referer-fallback helpers
#    (master_filters_from_referrer / active_state_filters_from_request) parse
#    the referer query via Rack::Utils.parse_nested_query. URI::InvalidURIError
#    was already rescued, but Rack's own parser errors leaked through:
#    ParameterTypeError (conflicting nesting like `a[]=1&a[b]=2`) and
#    ParamsTooDeepError (deeply nested keys) -> 500 on the inbox index and on
#    every member action rendering update.turbo_stream (mark_read etc.).
#
# The remaining examples pin unchanged behavior as regression guards:
# same-host referer redirect, malformed/foreign referer -> blank filters,
# valid inbox referer -> filters still extracted.
RSpec.describe 'Referer hardening', type: :request do
  let(:organisation) { create(:organisation) }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:member) { create(:user) }
  let(:admin) { create(:user) }

  let!(:member_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member, organisation: organisation, role: member_role, active: true)
    end
  end
  let!(:admin_membership) do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: admin, organisation: organisation, role: admin_role, active: true)
    end
  end

  before { ActsAsTenant.current_tenant = organisation }

  describe 'A) Pundit denial redirect (ApplicationController#user_not_authorized)' do
    before { sign_in member }

    it 'degrades to root_path on a cross-host referer instead of 500ing' do
      get organisation_settings_path(organisation),
          headers: { 'Referer' => 'http://evil.example.org/somewhere' }

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
    end

    it 'still redirects back to a same-host referer (pin)' do
      same_host_referer = "http://#{host}#{organisation_projects_path(organisation)}"
      get organisation_settings_path(organisation),
          headers: { 'Referer' => same_host_referer }

      expect(response).to redirect_to(same_host_referer)
      expect(flash[:alert]).to eq(I18n.t('shared.errors.not_authorized'))
    end

    it 'falls back to root_path without a referer (pin)' do
      get organisation_settings_path(organisation)

      expect(response).to redirect_to(root_path)
    end
  end

  describe 'B) Inbox referer-fallback parsing (NotificationsController)' do
    let!(:project) do
      ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) }
    end
    let!(:ticket) do
      ActsAsTenant.with_tenant(organisation) { create(:ticket, project: project) }
    end
    let!(:notification) do
      ActsAsTenant.with_tenant(organisation) do
        create(:notification, recipient: admin, organisation: organisation,
                              notifiable: ticket, project: project,
                              channel: 'in_app', state: :delivered)
      end
    end

    let(:inbox_path) { organisation_notifications_path(organisation) }
    # Conflicting nesting: `state_filters[]` (array) vs `state_filters[x]`
    # (hash) makes Rack::Utils.parse_nested_query raise ParameterTypeError.
    let(:conflicting_referer) do
      "http://#{host}#{inbox_path}?state_filters[]=unread&state_filters[x]=1"
    end
    # Nesting deeper than Rack's param depth limit raises ParamsTooDeepError.
    let(:too_deep_referer) do
      "http://#{host}#{inbox_path}?a#{'[b]' * 40}=1"
    end

    before do
      sign_in admin
      Prosopite.pause
    end
    after { Prosopite.resume }

    it 'index survives a referer with a conflicting nested query' do
      get inbox_path, params: { state_filters: ['unread'] },
                      headers: { 'Referer' => conflicting_referer }

      expect(response).to have_http_status(:ok)
    end

    it 'index survives a referer with a too-deeply nested query' do
      get inbox_path, params: { state_filters: ['unread'] },
                      headers: { 'Referer' => too_deep_referer }

      expect(response).to have_http_status(:ok)
    end

    it 'mark_read survives a referer with a conflicting nested query' do
      patch mark_read_organisation_notification_path(organisation, notification),
            headers: { 'Referer' => conflicting_referer,
                       'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(controller.instance_variable_get(:@active_state_filters)).to eq([])
    end

    it 'treats a referer with an invalid percent-encoding in the query as absent' do
      # A lone "%" survives URI.parse (unlike e.g. "%GG", which URI already
      # rejects upstream as InvalidURIError) and makes Rack's query parser
      # raise InvalidParameterError — pins that class in the rescue list.
      get inbox_path, params: { state_filters: ['unread'] },
                      headers: { 'Referer' => "http://#{host}#{inbox_path}?a=%" }

      expect(response).to have_http_status(:ok)
      expect(controller.send(:master_filters_from_referrer)[:state_filters]).to eq([])
    end

    it 'treats a malformed referer as absent (pin: URI::InvalidURIError already rescued)' do
      get inbox_path, params: { state_filters: ['unread'] },
                      headers: { 'Referer' => 'http://[invalid' }

      expect(response).to have_http_status(:ok)
      expect(controller.send(:master_filters_from_referrer)[:state_filters]).to eq([])
    end

    it 'ignores a cross-host referer with a foreign path (pin: path check -> blank)' do
      get inbox_path, params: { state_filters: ['unread'] },
                      headers: { 'Referer' => 'http://evil.example.org/anything?state_filters[]=read' }

      expect(response).to have_http_status(:ok)
      expect(controller.send(:master_filters_from_referrer)[:state_filters]).to eq([])
      # Params still win: state_filters came explicitly with the request.
      expect(controller.send(:active_state_filters_from_request)).to eq(['unread'])
    end

    it 'still extracts filters from a valid same-host inbox referer (regression pin)' do
      valid_referer = "http://#{host}#{organisation_notifications_path(
        organisation, state_filters: %w[unread read], view_mode: 'all', search: 'foo'
      )}"
      patch mark_read_organisation_notification_path(organisation, notification),
            headers: { 'Referer' => valid_referer,
                       'Accept' => 'text/vnd.turbo-stream.html' }

      expect(response).to have_http_status(:ok)
      expect(controller.instance_variable_get(:@active_state_filters)).to eq(%w[unread read])

      filters = controller.send(:master_filters_from_referrer)
      expect(filters[:state_filters]).to eq(%w[unread read])
      expect(filters[:view_mode]).to eq('all')
      expect(filters[:search]).to eq('foo')
    end
  end
end
