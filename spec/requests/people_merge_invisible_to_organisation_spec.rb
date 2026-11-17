# frozen_string_literal: true

require 'rails_helper'

# What: everything an ORGANISATION shows about its people answers the same with and without
#       a merge on those people: its people page, the lane of a merged row and of a merged
#       member, the REST list and card, the MCP tools find_people and get_person.
# Why:  a merge of the people above the organisations is one person's private note that a
#       row here and a row elsewhere are the same human. The organisation must never learn
#       that somebody knows its person elsewhere: not from a mark on a row, not from a
#       field of an API answer, not from an activity.
# How:  every surface is read before any merge exists, then the merges are written (by the
#       reader themselves and by a colleague), then every surface is read again. The two
#       answers must be equal byte for byte; what differs between ANY two requests (the
#       tokens of a form, the nonce of a script, ids drawn at random) is taken out first,
#       and a control compares two reads without a change between them.
RSpec.describe 'A merge of people is invisible to the organisations', :ci_guard, type: :request do
  include AllPeopleHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:owner) { create(:user, first_name: 'Vera', last_name: 'Viewer', email: 'vera@example.com') }
  let(:colleague) { create(:user, first_name: 'Karl', last_name: 'Kollege', email: 'karl@example.com') }
  let(:member) { create(:user, first_name: 'Mara', last_name: 'Mitglied', email: 'mara@example.com') }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }

  let!(:people) do
    Prosopite.pause do
      join_organisation(owner, north, admin: true)
      join_organisation(owner, south, admin: true)
      join_organisation(colleague, north, rights: ['view_people'])
      join_organisation(colleague, south, rights: ['view_people'])
      join_organisation(member, north)
      {
        north: person_in(north, name: 'Kai Kontakt', function: 'Einkauf', company: 'Nordlicht AG',
                                email: 'kai@example.com', phone: '+49 30 5550100', notes: 'Nur vormittags.'),
        south: person_in(south, name: 'Kai Kontakt', function: 'Vertrieb', company: 'Suedwind AG')
      }
    end
  end

  let(:tokens) do
    [owner, colleague].index_with do |user|
      build(:personal_access_token, user: user, organisations: [north]).tap do |token|
        token.token_hash = nil
        token.token_prefix = nil
        token.generate_token!
      end
    end
  end

  let(:frame) { { 'Turbo-Frame' => Organisations::PeopleController::DETAIL_FRAME_ID } }

  around { |example| freeze_time { example.run } }

  after { ActsAsTenant.current_tenant = nil }

  # What no two requests share, whatever happened between them.
  def stable(body)
    body.gsub(/(name="csrf-token" content=")[^"]+/, '\1')
        .gsub(/(name="authenticity_token" value=")[^"]+/, '\1')
        .gsub(/nonce="[^"]+"/, 'nonce=""')
        .gsub(/flash_\h{8}/, 'flash_X')
  end

  def html(path, headers: {})
    get path, headers: headers
    expect(response).to have_http_status(:ok)
    stable(response.body)
  end

  def rest(user, path)
    get "/api/v1/organisations/#{north.id}/people#{path}", headers: { 'Authorization' => "Bearer #{tokens[user].token}" }
    expect(response).to have_http_status(:ok)
    response.body
  end

  def mcp(user, tool, **arguments)
    post '/api/mcp', params: { jsonrpc: '2.0', id: 1, method: 'tools/call',
                               params: { name: tool, arguments: { organisation_id: north.id, **arguments } } }.to_json,
                     headers: { 'Authorization' => "Bearer #{tokens[user].token}", 'CONTENT_TYPE' => 'application/json' }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('result', 'isError')).to be_falsey
    response.body
  end

  # Every answer of the organisation north about its people, as this user gets it. The
  # member of north is seen by the account admin only (the reader shares no project with
  # them), so the member's surfaces are the admin's.
  def surfaces(user)
    sign_in user
    answers = {
      page: html(organisation_people_path(north)),
      contact_lane: html(organisation_person_path(north, people[:north]), headers: frame),
      contact_page: html(organisation_people_path(north, person_id: people[:north].id)),
      rest_list: rest(user, ''),
      rest_card: rest(user, "/person:#{people[:north].id}"),
      mcp_find: mcp(user, 'find_people'),
      mcp_get: mcp(user, 'get_person', id: "person:#{people[:north].id}")
    }
    return answers unless user == owner

    answers.merge(member_page: html(organisation_people_path(north, member_id: member.id)),
                  rest_member: rest(user, "/member:#{member.id}"),
                  mcp_member: mcp(user, 'get_person', id: "member:#{member.id}"))
  end

  def merge(user, *entries)
    result = Actors::MergePeople.call(entries: entries, current_user: User.find(user.id))
    expect(result).to be_success
  end

  def write_merges
    [owner, colleague].each do |user|
      merge(user, { org: north.id, id: "person:#{people[:north].id}" }, { org: south.id, id: "person:#{people[:south].id}" })
    end
    # A second group of the owner that names the member of north by account.
    other = person_in(south, name: 'Mara M. (privat)')
    merge(owner, { org: north.id, id: "member:#{member.id}" }, { org: south.id, id: "person:#{other.id}" })
  end

  def differences(before, after)
    before.keys.reject { |name| before[name] == after[name] }
  end

  [%i[owner an_account_admin_who_wrote_a_merge], %i[colleague a_reader_with_a_merge_of_their_own]].each do |who, what|
    it "answers #{what.to_s.tr('_', ' ')} the same with and without the merges, on every surface" do
      user = public_send(who)
      activities = -> { Activity.unscoped.count }

      Prosopite.pause do
        before = surfaces(user)
        again = surfaces(user)
        # The control: two reads with nothing between them are equal, so a difference
        # below would be the merges'.
        expect(differences(before, again)).to be_empty

        expect { write_merges }.not_to(change { activities.call })
        expect([PersonGroup.count, PersonGroupEntry.count]).to eq([3, 6])
        after = surfaces(user)

        expect(differences(before, after)).to be_empty
        # The surfaces are the real ones: each names the row, none an empty or refused page.
        expect(before.values_at(:page, :contact_lane, :contact_page, :rest_list, :rest_card, :mcp_find, :mcp_get))
          .to all(include('Kai Kontakt'))
        expect(before.values_at(:member_page, :rest_member, :mcp_member).compact).to all(include('Mara Mitglied'))
        expect(before.size).to eq(user == owner ? 10 : 7)
      end
    end
  end

  # The same merges ARE visible where they belong: on the owner's list above the
  # organisations. Without this the comparison above could be green because nothing was
  # merged at all.
  it 'shows the same merges on the list above the organisations of their owner' do
    Prosopite.pause { write_merges }
    sign_in owner

    get all_people_path

    rows = Nokogiri::HTML(response.body).css('tr[data-all-people-row]').to_h do |row|
      [row.at_css('.all-people-row__name').text.strip, row.css('[data-organisation-chip]').map { |chip| chip.text.strip }]
    end
    expect(rows).to include('Kai Kontakt' => ['Nord GmbH', 'Sued AG'], 'Mara Mitglied' => ['Nord GmbH', 'Sued AG'])
  end

  it 'adds no column to the people of an organisation and no key to their API rows' do
    expect(Person.column_names.grep(/group|merge/)).to be_empty
    expect(People::Lookup.row(People::Directory::Entry.new(kind: :contact, person: people[:north], sort_name: 'x')).keys)
      .to contain_exactly(:id, :name, :kind, :function, :department, :company, :last_contact)
  end
end
