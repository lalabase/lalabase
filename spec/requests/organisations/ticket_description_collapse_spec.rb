# frozen_string_literal: true

require 'rails_helper'

# Request specs for the collapsible ticket description on the detail page
# (tickets#show). The collapse / badge / info-box LOGIC is unit-tested in
# spec/presenters/ticket_description_state_spec.rb; this spec verifies the
# WIRING: the header partial instantiates the view-model, renders the right
# controls for each state, and the i18n keys resolve without a render error.
#
# The collapsed body is found via its collapse-controller body target (only
# the detail description carries it) and then checked for line-clamp-2, so
# the assertion cannot be fooled by an unrelated line-clamp elsewhere on the
# page - and does not break on every styling round either (the exact class
# combo pin went stale silently once already).
RSpec.describe 'Ticket description collapse (detail view)', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, organisation: organisation, creator: user,
                    content: 'Original description body')
  end

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation,
                        role: create(:admin_role, organisation: organisation))
    sign_in user
  end

  def header_t(key)
    # The LIVE scope the view renders from (fully qualified via its sh prefix).
    # T6 deleted the orphaned lazy tree organisations.tickets.ticket_header_show
    # this helper used to read - same values, wrong owner.
    I18n.t("views.organisations.tickets.ticket_header_show.#{key}")
  end

  def own_comment!
    create(:post, ticket: ticket, user: user, organisation: organisation)
  end

  def get_detail
    get organisation_project_ticket_path(organisation, project, ticket)
  end

  # The collapse body target's class list, or nil when no collapsible
  # description rendered.
  def body_classes
    node = Nokogiri::HTML5.fragment(response.body)
                          .at_css('[data-ticket-description-collapse-target="body"]')
    node && node[:class]
  end

  context 'when the ticket is unknown (user has not commented)' do
    it 'renders the full description without the collapse controller or info box' do
      get_detail

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Original description body')
      expect(response.body).not_to include('data-controller="ticket-description-collapse"')
      expect(response.body).not_to include(header_t('description_infobox_text'))
    end
  end

  context 'when the ticket is known (user has commented)' do
    before { own_comment! }

    it 'collapses with the default preference and shows the info box' do
      get_detail

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="ticket-description-collapse"')
      expect(body_classes).to include('line-clamp-2')
      expect(response.body).to include(header_t('description_show_full'))
      expect(response.body).to include(header_t('description_infobox_text'))
    end

    it 'collapses without the info box once the user chose auto' do
      user.preference_store.set('description_collapse', 'auto')

      get_detail

      expect(body_classes).to include('line-clamp-2')
      expect(response.body).not_to include(header_t('description_infobox_text'))
    end

    it 'expands without the info box when the user chose always_full' do
      user.preference_store.set('description_collapse', 'always_full')

      get_detail

      expect(response.body).to include('data-controller="ticket-description-collapse"')
      expect(body_classes).not_to include('line-clamp-2')
      expect(response.body).not_to include(header_t('description_infobox_text'))
    end
  end

  context 'when the description changed after the last comment' do
    it 'shows the "description changed" badge' do
      travel_to(Time.zone.local(2026, 6, 1, 10, 0, 0)) { ticket }
      travel_to(Time.zone.local(2026, 6, 1, 11, 0, 0)) { own_comment! }
      travel_to(Time.zone.local(2026, 6, 1, 12, 0, 0)) { ticket.update!(content: 'Edited later') }
      user.preference_store.set('description_collapse', 'auto')

      get_detail

      expect(response.body).to include(header_t('description_changed'))
    end
  end
end
