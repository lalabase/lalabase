# frozen_string_literal: true

require 'rails_helper'

# What: the REST people list and MCP find_people answer the same rows for the same data, and
#   the REST card is the MCP card plus the notes (People S3b).
# Why: two surfaces for one question become two answers as soon as one of them builds its
#   own rows (cli_rest_plan, risk "two answers"). Both go through People::Lookup.row and
#   .card; this compares what reaches the wire, last contacts included.
RSpec.describe 'People on REST and MCP', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user, first_name: 'Anna', last_name: 'Albers') }
  let(:colleague) { create(:user, first_name: 'Carl', last_name: 'Kollege') }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }
  let(:contact) do
    ActsAsTenant.with_tenant(organisation) do
      create(:person, organisation: organisation, name: 'Doris Dienstleister', salutation: 'Frau',
                      function: 'Leitung IT', department: 'Technik', company: 'Hosting AG',
                      email: 'doris@example.com', phone: '+49 30 1234567', notes: 'Nur vormittags anrufen.',
                      additional_details: [{ 'kind' => 'url', 'label' => '', 'value' => 'https://example.com' }])
    end
  end

  before do
    Prosopite.pause do
      ActsAsTenant.with_tenant(organisation) do
        role = create(:role, organisation: organisation)
        create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
        create(:membership, user: user, organisation: organisation, role: role, active: true)
        create(:membership, user: colleague, organisation: organisation, role: create(:role, organisation: organisation),
                            active: true)
        create(:project_permission, user: user, project: project, tickets_access: :read_only, meetings_access: :read_only)
        create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
        create(:person, organisation: organisation, user: colleague, name: 'C. K.', function: 'Einkauf', phone: '+49 30 7654321')
        create(:person, organisation: organisation, name: 'Jürgen Müller', company: 'Nordlicht AG')
        # A last contact of each kind: a meeting for the contact, own ticket work for the member.
        meeting = create(:meeting, organisation: organisation, project: project, occurred_at: 4.days.ago)
        create(:meeting_participant, meeting: meeting, person: contact, display_name: 'Gast')
        ticket = create(:ticket, organisation: organisation, project: project)
        Activity.create!(actor: colleague, trackable: ticket, organisation: organisation, action: 'created',
                         parameters: { 'skip_notifications' => true }, created_at: 2.days.ago)
      end
    end
  end

  let(:pat) do
    build(:personal_access_token, user: user, organisations: [organisation]).tap do |token|
      token.token_hash = nil
      token.token_prefix = nil
      token.generate_token!
    end
  end

  def rest(path, **query)
    get "/api/v1/organisations/#{organisation.id}/people#{path}", params: query,
                                                                  headers: { 'Authorization' => "Bearer #{pat.token}" }
    expect(response).to have_http_status(:ok)
    response.parsed_body['data']
  end

  def mcp(tool, **arguments)
    post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/call',
                               params: { name: tool, arguments: arguments.merge(organisation_id: organisation.id) } }.to_json,
                     headers: { 'Authorization' => "Bearer #{pat.token}", 'CONTENT_TYPE' => 'application/json' }
    result = response.parsed_body['result']
    expect(result['isError']).to be_falsey, result.inspect
    JSON.parse(result.dig('content', 0, 'text'))
  end

  it 'lists the same rows on both, last contacts included' do
    rows = rest('')

    expect(rows.pluck('name')).to eq(['Anna Albers', 'Carl Kollege', 'Doris Dienstleister', 'Jürgen Müller'])
    expect(rows.filter_map { |row| row['last_contact']&.fetch('kind') }).to contain_exactly('meeting', 'ticket')
    expect(mcp('find_people')['data']).to eq(rows)
  end

  it 'searches and filters alike' do
    expect(mcp('find_people', query: 'mueller')['data']).to eq(rest('', q: 'mueller'))
    expect(mcp('find_people', kind: 'contacts')['data']).to eq(rest('', kind: 'contacts'))
  end

  it 'gives the REST card the MCP card plus the notes' do
    card = rest("/person:#{contact.id}")

    expect(card.except('notes')).to eq(mcp('get_person', id: "person:#{contact.id}"))
    expect(card['notes']).to eq('Nur vormittags anrufen.')
    expect(rest("/member:#{colleague.id}").except('notes')).to eq(mcp('get_person', id: "member:#{colleague.id}"))
  end
end
