# frozen_string_literal: true

require 'rails_helper'

# The header of a search hit: what it is, which project, and since when the
# information exists. The service hands out stable keys (type, match types) and a
# date; the view owns the words, in the language of the request.
RSpec.describe 'Power search result header', type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:role) { create(:admin_role, organisation: organisation) }
  let(:hit) do
    {
      type: :post,
      title: 'Export der Kundenliste',
      link: '#',
      project_name: 'Beispielprojekt',
      project_link: nil,
      date: Time.zone.local(2025, 3, 12, 10),
      content: 'Eine mögliche Abfrage',
      highlighted_content: nil,
      similarity: 0.9,
      match_types: %i[fulltext semantic],
      highlight: nil
    }
  end

  before do
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: user, organisation: organisation, role: role, active: true)
    end
    ActsAsTenant.current_tenant = organisation
    sign_in user
    service = instance_double(PowerSearchService, execute: [hit], semantic_degraded?: false)
    allow(PowerSearchService).to receive(:new).and_return(service)
  end

  def header_for(locale)
    post organisation_power_search_path(organisation_id: organisation.id, locale: locale),
         params: { power_search_query: 'abfrage' }
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body).at_css('.posts-container p').text.squish
  end

  it 'names the type, the project, the date and the match types in German' do
    expect(header_for(:de)).to eq('Kommentar Beispielprojekt 12.03.2025 Volltext Treffer Semantischer Treffer')
  end

  it 'names them in English' do
    expect(header_for(:en)).to eq('Comment Beispielprojekt 2025-03-12 Full-text match Semantic match')
  end

  it 'marks the date up as a machine-readable time' do
    header_for(:de)
    time = Nokogiri::HTML(response.body).at_css('.posts-container time')
    expect(time['datetime']).to eq('2025-03-12')
  end

  it 'leaves the date out when the hit has none' do
    hit[:date] = nil
    expect(header_for(:de)).to eq('Kommentar Beispielprojekt Volltext Treffer Semantischer Treffer')
  end
end
