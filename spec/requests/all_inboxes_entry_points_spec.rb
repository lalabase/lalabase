# frozen_string_literal: true

require 'rails_helper'

# What: the ways to the inbox above the organisations (GET /inbox): a row in the
#       organisation switcher, an entry in the account list (the cockpit's sidebar
#       and the account layer), a link at the cockpit's heading in both layouts,
#       and a row on the phone's "Mehr" page.
# Why:  until S2 the page was reached only by typing its address. Each way shows
#       for a person with two or more organisations and for nobody else (the route
#       sends a person with one to the inbox of that one). Every check that a way
#       is absent first proves the page around it rendered.
RSpec.describe 'Ways to the inbox above the organisations', type: :request do
  let(:user) { create(:user) }
  let(:north) { create(:organisation, name: 'Nordwind GmbH') }
  let(:south) { create(:organisation, name: 'Suedhang AG') }

  def join(org)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, role: create(:admin_role, organisation: org), active: true)
    end
  end

  def unread_in(org)
    ActsAsTenant.with_tenant(org) do
      create(:notification, recipient: user, organisation: org, project: nil,
                            event_type: 'mention', channel: 'in_app', state: :delivered)
    end
  end

  def doc_of(path)
    get path
    expect(response).to have_http_status(:ok), response.location.to_s
    Nokogiri::HTML5(response.body)
  end

  def inbox_links(doc)
    doc.css("a[href='#{all_inboxes_path}']")
  end

  def follow(link)
    get link['href']
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML5(response.body).at_css('[data-all-inboxes]')).to be_present
  end

  before do
    join(north)
    sign_in user
    Prosopite.pause # the pages below have known N+1 in their own render paths
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  context 'with two organisations' do
    before do
      join(south)
      unread_in(north)
    end

    it 'has a row in the switcher, without a count, and it leads to the page' do
      doc = doc_of(organisation_notifications_path(north, state_filters: %w[read unread]))

      row = doc.at_css('[data-all-inboxes-entry="switcher"]')
      expect(row).to be_present
      expect(row['href']).to eq(all_inboxes_path)
      expect(row.text.squish).to eq(I18n.t('navigation.all_inboxes'))
      expect(row.css('[id^="org_attention_count"]')).to be_empty
      follow(row)
    end

    it 'has an entry in the account list of the cockpit' do
      doc = doc_of(select_organisation_path)

      entry = doc.at_css("[data-account-nav-list] a[href='#{all_inboxes_path}']")
      expect(entry).to be_present
      expect(entry.text.squish).to include(I18n.t('navigation.all_inboxes'))
      follow(entry)
    end

    %w[stacked rows_compact rows_detailed].each do |layout|
      it "has the link at the cockpit's heading in the #{layout} layout" do
        user.preference_store.update('cockpit_layout' => layout)
        doc = doc_of(select_organisation_path)

        expect(doc.at_css('#cockpit-summary-heading, #cockpit-rows-heading')).to be_present
        link = doc.at_css('[data-all-inboxes-entry="cockpit"]')
        expect(link).to be_present
        expect(link.text.squish).to eq(I18n.t('views.organisations.select.cockpit.all_inboxes'))
        follow(link)
      end
    end

    it 'has a row on the phone\'s "Mehr" page' do
      doc = doc_of(organisation_mobile_more_path(north))

      row = doc.at_css('[data-all-inboxes-entry="mobile"]')
      expect(row).to be_present
      follow(row)
    end
  end

  context 'with one organisation' do
    before { unread_in(north) }

    it 'has no row in the switcher' do
      doc = doc_of(organisation_notifications_path(north, state_filters: %w[read unread]))

      expect(doc.at_css('[data-controller~="details-autoclose"], nav')).to be_present
      expect(doc.at_css('[data-all-inboxes-entry="switcher"]')).to be_nil
      expect(inbox_links(doc)).to be_empty
    end

    it 'has no entry in the account list and no link at the cockpit' do
      doc = doc_of(select_organisation_path)

      expect(doc.at_css('[data-account-nav-list]')).to be_present
      expect(doc.at_css('#cockpit-summary-heading')).to be_present
      expect(inbox_links(doc)).to be_empty
    end

    it 'has no row on the phone\'s "Mehr" page' do
      doc = doc_of(organisation_mobile_more_path(north))

      expect(doc.at_css('.mobile-person')).to be_present
      expect(doc.at_css('[data-all-inboxes-entry="mobile"]')).to be_nil
    end
  end
end
