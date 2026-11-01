# frozen_string_literal: true

require 'rails_helper'

# Guard: the ticket detail's top chrome row (designer round 8a, 05.09.2026).
#
# One rank for the action cluster: identical frameless 32x32 icon surfaces
# (pencil, spark, dots) with the 6px radius, a divider, then the exit in the
# SAME rank. Icon only - words above the title would compete with the title,
# so every surface carries a title attribute instead. And editing happens at
# the object too: a click on the title opens the same editor the pencil
# opens (writing_surface frame) - the pencil stays for those who look for
# it. The description does NOT take part: it had the same click-to-edit
# with a hover surface and lost it on user decision (10.09.2026), because
# the hover made the whole text read as one big button.
RSpec.describe 'Ticket header actions', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) do
    ActsAsTenant.current_tenant = organisation
    create(:project, organisation: organisation)
  end
  let(:ticket) do
    ActsAsTenant.current_tenant = organisation
    create(:ticket, project: project, organisation: organisation, creator: user,
                    content: 'Beschreibungstext im Kopf')
  end

  # The one rank every surface in the cluster shares: 32x32, 6px radius,
  # cream-500 at rest, darker text on a cream-200 surface on hover/focus.
  # A let, not a constant: a constant in an RSpec block lands on Object.
  let(:rank_classes) { %w[h-8 w-8 rounded-md text-cream-500 hover:bg-cream-200 hover:text-cream-900] }

  let(:document) { Nokogiri::HTML5.fragment(response.body) }

  def header_t(key)
    I18n.t("views.organisations.tickets.ticket_header_show.#{key}")
  end

  def get_detail
    get organisation_project_ticket_path(organisation, project, ticket)
  end

  after { ActsAsTenant.current_tenant = nil }

  context 'as a writer' do
    before do
      ActsAsTenant.current_tenant = organisation
      create(:membership, user: user, organisation: organisation,
                          role: create(:admin_role, organisation: organisation))
      sign_in user
      get_detail
    end

    it 'renders the pencil icon-only, the words in its title' do
      pencil = document.at_css(%(a[title="#{header_t('edit_ticket')}"]))
      expect(pencil).to be_present
      expect(pencil.text.strip).to eq('')
      expect(pencil.at_css('i.bi-pencil')).to be_present
      expect(pencil['data-turbo-frame']).to eq('writing_surface')
      rank_classes.each { |css| expect(pencil[:class]).to include(css) }
    end

    it 'gives the dots trigger and the exit the same rank as the pencil' do
      dots = document.at_css(%(button[title="#{header_t('more_actions')}"]))
      exit_button = document.at_css(%(button[title="#{header_t('close_detail')}"]))
      expect(dots).to be_present
      expect(exit_button).to be_present
      [dots, exit_button].each do |surface|
        rank_classes.each { |css| expect(surface[:class]).to include(css) }
      end
    end

    it 'makes the title a click-to-edit link into the writing surface' do
      title_link = document.at_css('h2 a')
      expect(title_link).to be_present
      expect(title_link.text).to include(ticket.title)
      expect(title_link['href'])
        .to eq(edit_organisation_project_ticket_path(organisation, project, ticket))
      expect(title_link['data-turbo-frame']).to eq('writing_surface')
      expect(title_link['title']).to eq(header_t('edit_ticket'))
    end

    it 'leaves the description plain text: no click handler, no hover surface' do
      body = document.css('div.prose').find { |div| div.text.include?('Beschreibungstext im Kopf') }
      expect(body).to be_present
      expect(body['data-controller']).to be_nil
      expect(body['data-action']).to be_nil
      expect(body[:class]).not_to match(/hover:/)
      expect(response.body).not_to include('ticket-inline-edit')
    end
  end

  context 'as a reader (tickets read_only)' do
    before do
      ActsAsTenant.current_tenant = organisation
      create(:membership, user: user, organisation: organisation,
                          role: create(:role, organisation: organisation))
      create(:project_permission, user: user, project: project, tickets_access: 'read_only')
      sign_in user
      get_detail
    end

    it 'renders the page without any edit affordance' do
      expect(response).to have_http_status(:ok)
      expect(document.at_css(%(a[title="#{header_t('edit_ticket')}"]))).to be_nil
      expect(document.at_css('h2 a')).to be_nil
      expect(document.text).to include(ticket.title)
      expect(response.body).not_to include('ticket-inline-edit')
    end
  end
end
