# frozen_string_literal: true

require 'rails_helper'

# What: the people above the organisations (GET /people). One list over the people of
#       every organisation a person is an active member of and holds the people right in:
#       each row names its lead organisation as a chip and the others as "+N", a member
#       with the same account in two organisations is one row, a row opens its card.
# Why:  the page reads across tenants, so everything it must NOT show is pinned here: an
#       organisation without the people right (not even its name), a left organisation,
#       contact details and notes, an address that could move the session's organisation,
#       an assistant on a page without an organisation.
RSpec.describe 'People above the organisations', :ci_guard, type: :request do
  include AllPeopleHelpers

  let(:user) { create(:user, first_name: 'Vera', last_name: 'Viewer', email: 'vera@example.com') }
  let(:shared) { create(:user, first_name: 'Mara', last_name: 'Mitglied', email: 'mara@example.com') }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }

  # The fixtures repeat lookups per organisation (roles, memberships); the requests below
  # are what Prosopite watches.
  let!(:people) do
    Prosopite.pause do
      # South first: the organisation with the later name is the older one, so the order
      # by name on the page is not the order of creation.
      join_organisation(user, south, admin: true)
      join_organisation(user, north, admin: true)
      join_organisation(shared, south)
      join_organisation(shared, north)
      {
        north_row: person_in(north, user: shared, name: 'Mara Mitglied', function: 'Beraterin', company: nil,
                                    email: 'mara.lager@example.com', phone: '+49 30 5550100', notes: 'Nur dienstags im Haus.'),
        north_contact: person_in(north, name: 'Nora Nord', function: 'Leitung IT', company: 'Hosting AG',
                                        email: 'nora@example.com', phone: '+49 30 5550199',
                                        notes: 'Bitte nicht vor zehn anrufen.',
                                        additional_details: [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '+49 170 5550177' }]),
        south_contact: person_in(south, name: 'Sina Sued', function: 'Vertrieb', company: 'Suedwind AG',
                                        email: 'sina@example.com', phone: '+49 89 5550123')
      }
    end
  end

  before { sign_in user }

  after { ActsAsTenant.current_tenant = nil }

  def page(**params)
    get all_people_path(**params)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def list(doc)
    doc.at_css('[data-all-people]').tap { |element| expect(element).to be_present }
  end

  def rows(doc)
    list(doc).css('tr[data-all-people-row]')
  end

  def row_of(doc, name)
    rows(doc).find { |row| row.at_css('.all-people-row__name').text.strip == name }
  end

  def names(doc)
    rows(doc).map { |row| row.at_css('.all-people-row__name').text.strip }
  end

  def chips(row)
    row.css('[data-organisation-chip]')
  end

  # The organisations a row names: the chip of its lead source, then the others that its
  # "+N" names in its title (D14).
  def organisations(row) = row_organisations(row)

  def filter_options(doc)
    doc.css('#all-people-organisation option').map { |option| option.text.strip }
  end

  describe 'the list' do
    it 'shows the people of every organisation in one list, by name, each row with its organisations as chips' do
      doc = page

      expect(names(doc)).to eq(['Mara Mitglied', 'Nora Nord', 'Sina Sued', 'Vera Viewer'])
      expect(rows(doc).map { |row| organisations(row) })
        .to eq([['Nord GmbH', 'Sued AG'], ['Nord GmbH'], ['Sued AG'], ['Nord GmbH', 'Sued AG']])
      expect(rows(doc).map { |row| chips(row).size }).to eq([1, 1, 1, 1])
      expect(doc.at_css('[data-all-people-count]').text).to eq(I18n.t('views.all_people.count', count: 4))
    end

    # D14: one chip, the lead's, and "+N" for the others, at every width. "+N" is text:
    # a click on the row opens the card. A screen reader hears every organisation.
    it 'shows the chip of the lead source and "+N", with the other organisations in its title and for a screen reader' do
      Prosopite.pause do
        person_in(south, user: shared, name: 'Mara Mitglied', function: 'Beraterin', company: 'Suedwind AG',
                         department: 'Vertrieb', phone: '+49 89 5550100')
      end

      row = row_of(page, 'Mara Mitglied')

      expect(chips(row).map { |chip| chip.text.strip }).to eq(['Sued AG'])
      more = row.at_css('[data-row-more]')
      expect([more.name, more.text.strip, more['title']]).to eq(['span', '+1', 'Nord GmbH'])
      expect(more['aria-hidden']).to eq('true')
      expect(row.at_css('.all-people-chips .sr-only').text.strip).to eq(I18n.t('views.all_people.more.names', count: 1, names: 'Nord GmbH'))
      expect(row.css('a, button, details')).to be_empty
      # The row still names the person by the first source, and opens the card of the first source.
      expect(row.at_css('.all-people-row__name').text.strip).to eq('Mara Mitglied')
      expect(row['data-list-row-id-value']).to eq("#{north.id}:member:#{shared.id}")
    end

    it 'shows what a person does and when the last contact was' do
      Prosopite.pause { meeting_in(north, at: 3.days.ago, person: people[:north_contact]) }

      row = row_of(page, 'Nora Nord')

      expect(row.at_css('.all-people-row__role').text.strip).to eq('Leitung IT · Hosting AG')
      expect(row.at_css('.all-people-row__last').text.strip).to eq(I18n.t('views.organisations.people.age.days', count: 3))
    end

    it 'gives every chip the recognition colour the person set for that organisation' do
      user.org_colors.set(north, '#d1fae5')
      user.org_colors.set(south, OrgColor::OFF)
      user.save!

      doc = page
      swatches = ['Vera Viewer', 'Sina Sued'].map do |name|
        chips(row_of(doc, name)).map { |chip| chip.at_css('.organisation-chip__swatch')['style'] }
      end

      expect(swatches).to eq([['background-color: #d1fae5;'], [nil]])
    end

    it 'carries no contact details and no notes' do
      get all_people_path

      expect(response.body).to include('Nora Nord', 'Sina Sued', 'Leitung IT')
      expect(response.body).not_to match(/nora@example\.com|sina@example\.com|mara\.lager@example\.com|mara@example\.com/)
      expect(response.body).not_to match(/5550199|5550100|5550123|5550177|anrufen|dienstags/)
    end
  end

  describe 'where a row leads' do
    # Since the card exists a row opens it in the lane, and the way into an organisation is
    # on the card: the chip of the line under the name, and for several sources the chips
    # its "+N" opens to (spec/requests/all_people_card_spec.rb holds the card).
    def card_links(address)
      get all_people_path(card: address), headers: { 'Turbo-Frame' => AllPeopleController::CARD_FRAME_ID }
      expect(response).to have_http_status(:ok)
      where = Nokogiri::HTML(response.body).at_css('[data-card-where]')
      where.at_css('[data-card-more]') ? where.css('[data-card-more] a[data-organisation-chip]') : where.css('a[data-organisation-chip]')
    end

    it 'opens the card of a person of one organisation, which links to that organisation\'s people page with the person open' do
      row = row_of(page, 'Sina Sued')
      address = "#{south.id}:person:#{people[:south_contact].id}"

      expect(row['data-list-row-url-value']).to eq(all_people_path(card: address))
      expect(row.css('a')).to be_empty
      expect(row.at_css('.all-people-row__name').name).to eq('span')
      expect(chips(row).map(&:name)).to eq(['span'])
      links = card_links(address)
      expect(links.pluck('href')).to eq([organisation_people_path(south, person_id: people[:south_contact].id)])
      expect(links.pluck('data-turbo-frame')).to eq(['_top'])
    end

    it 'opens the card of a person of two organisations, which links into each of them, and the row itself nowhere' do
      row = row_of(page, 'Mara Mitglied')
      # A member is addressed by the account, with a row or without one.
      address = "#{north.id}:member:#{shared.id}"

      expect(row['data-list-row-url-value']).to eq(all_people_path(card: address))
      expect(row.css('a')).to be_empty
      expect(chips(row).map(&:name)).to eq(['span'])
      expect(row.at_css('[data-row-more]').name).to eq('span')
      expect(row.at_css('.all-people-row__name').name).to eq('span')
      links = card_links(address)
      expect(links.pluck('href')).to eq(
        [organisation_people_path(north, person_id: people[:north_row].id),
         organisation_people_path(south, member_id: shared.id)]
      )
      expect(links.pluck('data-turbo-frame')).to eq(%w[_top _top])
    end

    it 'carries no parameter named organisation_id in any address of the page' do
      doc = page(q: 'a', org: north.id, card: "#{north.id}:person:#{people[:north_contact].id}")

      # With the card of a person open: the link into the organisation stands on it.
      addresses = doc.css('[href], [action], [src], [data-list-row-url-value]').flat_map do |node|
        %w[href action src data-list-row-url-value].filter_map { |name| node[name] }
      end
      expect(addresses).to include(organisation_people_path(north, person_id: people[:north_contact].id))
      expect(addresses).to include(a_string_matching(/card=/))
      expect(addresses.grep(/organisation_id/)).to be_empty
    end
  end

  describe 'a reference is not a right' do
    it 'shows nothing of an organisation where the person lacks the people right, not even its name' do
      Prosopite.pause { take_people_right(user, south) }

      doc = page

      expect(names(doc)).to eq(['Mara Mitglied', 'Nora Nord', 'Vera Viewer'])
      expect(rows(doc).flat_map { |row| organisations(row) }.uniq).to eq(['Nord GmbH'])
      expect(filter_options(doc)).to eq([I18n.t('views.all_people.filter.all_organisations'), 'Nord GmbH'])
      expect(list(doc).text).to include('Nora Nord')
      expect(list(doc).text).not_to include('Sued AG', 'Sina Sued', 'Suedwind')
      expect(list(doc).to_html).not_to include(south.id)
    end

    it 'shows nothing of an organisation the person left, anywhere on the page' do
      Prosopite.pause do
        join_organisation(user, create(:organisation, name: 'West KG'), admin: true)
        Membership.find_by!(user: user, organisation: south).update!(active: false)
      end

      get all_people_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Nora Nord', 'Nord GmbH', 'West KG')
      expect(response.body).not_to include('Sued AG', 'Sina Sued', 'Suedwind', south.id)
    end

    it 'says so when the person may see the people of none of their organisations' do
      Prosopite.pause { [north, south].each { |organisation| take_people_right(user, organisation) } }

      doc = page

      expect(rows(doc)).to be_empty
      expect(list(doc).at_css('[data-all-people-empty="no-right"]')).to be_present
      expect(filter_options(doc)).to eq([I18n.t('views.all_people.filter.all_organisations')])
      expect(list(doc).text).not_to include('Nord GmbH', 'Sued AG', 'Nora Nord')
    end
  end

  describe 'a reference is not a right, with a search' do
    # A search in the address (a bookmark) must not turn "you may not see people" into
    # "nobody matches".
    it 'still says that the right is missing when the person may see the people of no organisation' do
      Prosopite.pause { [north, south].each { |organisation| take_people_right(user, organisation) } }

      doc = page(q: 'nora')

      expect(list(doc).at_css('[data-all-people-empty="no-right"]')).to be_present
      expect(list(doc).at_css('[data-all-people-empty="no-hits"]')).to be_nil
      expect(rows(doc)).to be_empty
    end
  end

  describe 'the search' do
    it 'narrows the list and shows the whole person for a match in one organisation' do
      doc = page(q: 'beraterin')

      expect(names(doc)).to eq(['Mara Mitglied'])
      expect(organisations(rows(doc).first)).to eq(['Nord GmbH', 'Sued AG'])
    end

    it 'answers the list frame with the rows and the tools that carry the search' do
      get all_people_path(q: 'sina'), headers: { 'Turbo-Frame' => AllPeopleController::LIST_FRAME_ID }

      doc = Nokogiri::HTML(response.body)
      expect(doc.css('tr[data-all-people-row] .all-people-row__name').map { |name| name.text.strip }).to eq(['Sina Sued'])
      stream = doc.at_css('turbo-frame#all_people_results turbo-stream[action="replace"][target="all_people_tools"]')
      expect(stream).to be_present
      expect(stream.to_html).to include('name="q"', 'value="sina"')
    end

    it 'says so when nothing matches, and offers the way back' do
      doc = page(q: 'niemand', org: north.id)

      empty = list(doc).at_css('[data-all-people-empty="no-hits"]')
      expect(empty.text).to include('niemand')
      expect(empty.at_css('a')['href']).to eq(all_people_path(org: north.id))
    end

    it 'does not find a member by an address they do not show' do
      expect(names(page(q: 'nord'))).to include('Nora Nord')
      expect(rows(page(q: 'mara.lager'))).to be_empty
    end
  end

  describe 'the organisation filter' do
    it 'narrows to the organisation `org` names and marks it in the select' do
      doc = page(org: south.id)

      expect(names(doc)).to eq(['Mara Mitglied', 'Sina Sued', 'Vera Viewer'])
      expect(rows(doc).flat_map { |row| organisations(row) }.uniq).to eq(['Sued AG'])
      # One source per row: one chip and no "+N", also for the member of both.
      expect(rows(doc).map { |row| [chips(row).size, row.at_css('[data-row-more]')] }).to eq([[1, nil]] * 3)
      expect(doc.at_css('#all-people-organisation option[selected]').text.strip).to eq('Sued AG')
      expect(filter_options(doc)).to eq([I18n.t('views.all_people.filter.all_organisations'), 'Nord GmbH', 'Sued AG'])
    end

    it 'answers a foreign, a missing, a malformed and a left organisation, and one without the right, with the same 404' do
      foreign = create(:organisation, name: 'Fremd GmbH')
      left = create(:organisation, name: 'Verlassen AG')
      without_right = create(:organisation, name: 'Ohne Recht AG')
      Prosopite.pause do
        person_in(foreign, name: 'Frieda Fremd')
        join_organisation(user, left, admin: true, active: false)
        join_organisation(user, without_right)
      end

      # Several requests on purpose (one answer for all of them); Prosopite reads the same
      # lookups of a second request as N+1.
      answers = Prosopite.pause do
        [foreign.id, SecureRandom.uuid, 'oops', left.id, without_right.id, [north.id], { id: north.id }].map do |org|
          get all_people_path, params: { org: org }
          [response.status, response.body]
        end
      end

      expect(answers.size).to eq(7)
      expect(answers.uniq).to eq([[404, '']])
      expect(Prosopite.pause { names(page(org: north.id)) }).to include('Nora Nord')
    end
  end

  describe 'pages' do
    it 'shows 50 rows per page and leads to the next one, keeping search and organisation' do
      Prosopite.pause { (1..51).each { |number| person_in(north, name: format('Anton Beispiel %02d', number)) } }

      first = page(q: 'anton', org: north.id)
      second = page(q: 'anton', org: north.id, page: 2)

      expect(names(first).size).to eq(50)
      expect(list(first).at_css('a[rel="next"]')['href']).to eq(all_people_path(q: 'anton', org: north.id, page: 2))
      expect(list(first).at_css('a[rel="prev"]')).to be_nil
      expect(names(second)).to eq(['Anton Beispiel 51'])
      expect(list(second).at_css('a[rel="prev"]')['href']).to eq(all_people_path(q: 'anton', org: north.id))
    end
  end

  describe 'the session and the tenant' do
    it 'keeps working in the organisation it was in' do
      get organisation_people_path(north)
      expect(session[:current_organisation_id]).to eq(north.id)

      page(org: south.id)
      expect(session[:current_organisation_id]).to eq(north.id)
    end

    it 'leaves no tenant behind' do
      page

      expect(ActsAsTenant.current_tenant).to be_nil
    end

    it 'leaves no tenant behind when the read raises inside an organisation' do
      allow(People::Lookup).to receive(:row).and_raise(ArgumentError, 'broken row')

      expect { get all_people_path }.to raise_error(ArgumentError, 'broken row')
      expect(ActsAsTenant.current_tenant).to be_nil
    end
  end

  describe 'Back in the browser' do
    # Turbo keeps a copy of a page for Back, with the option chosen in the select and the
    # text typed into the search at that moment. Restored, they would not match the address
    # (and choosing that organisation again would do nothing), so the page is fetched again.
    it 'is not kept for Back: Turbo fetches it again' do
      doc = page

      expect(doc.at_css('meta[name="turbo-cache-control"]')['content']).to eq('no-cache')
      expect(names(doc)).to include('Nora Nord')
    end
  end

  describe 'the assistant' do
    # The page has no organisation, so it has no assistant and sends no page context,
    # whatever the gate of an organisation says.
    it 'draws no assistant trigger and no assistant context' do
      allow(ChatPolicy).to receive(:assistant_gate_open?).and_return(true)

      # The same gate draws the panel and its trigger on a page of an organisation.
      Prosopite.pause { get organisation_people_path(north) }
      expect(response.body).to include('id="assistant_panel"', 'data-controller="assistant-trigger"')

      get all_people_path
      expect(response.body).to include('Nora Nord')
      expect(response.body).not_to include('id="assistant_panel"', 'data-controller="assistant-panel"',
                                           'data-controller="assistant-trigger"', 'data-assistant-context')
    end
  end

  describe 'who gets the page' do
    it 'sends a person with one organisation to the people page of that organisation' do
      Membership.find_by!(user: user, organisation: south).update!(active: false)

      get all_people_path

      expect(response).to redirect_to(organisation_people_path(north))
    end

    it 'sends a person without any organisation where such a person belongs, not to an empty list' do
      sign_out user
      sign_in create(:user)

      get all_people_path

      expect(response).to redirect_to(select_organisation_path)
    end

    it 'asks a visitor to sign in' do
      sign_out user

      get all_people_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
