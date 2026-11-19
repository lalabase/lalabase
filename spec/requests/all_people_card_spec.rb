# frozen_string_literal: true

require 'rails_helper'

# What: the card of a person in the lane of the people list above the organisations
#   (GET /people?card=<organisation id>:<entry address>): the values of every source side
#   by side, the organisation named where the sources differ, the switch that names it
#   everywhere, a pencil per source that leads to the form in that organisation.
# Type: Request spec over real rows in two organisations.
# Why:  the card shows contact details and notes of several tenants on a page without one.
#   Pinned here: a source the viewer may not read is absent with everything it holds; an
#   address that names nothing answers one body; no pencil without the right to write
#   there and none at what belongs to an account; the notes stay on the card; the session
#   and the tenant are where they were after the request.
RSpec.describe 'People above the organisations, the card', :ci_guard, type: :request do
  include AllPeopleHelpers

  let(:user) { create(:user, first_name: 'Vera', last_name: 'Viewer', email: 'vera@example.com') }
  let(:shared) { create(:user, first_name: 'Mara', last_name: 'Mitglied', email: 'mara@example.com') }
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }

  let!(:people) do
    Prosopite.pause do
      join_organisation(user, south, admin: true)
      join_organisation(user, north, admin: true)
      join_organisation(shared, south)
      join_organisation(shared, north)
      {
        north_kai: person_in(north, name: 'Kai Kontakt', salutation: 'Herr', function: 'Einkauf', company: 'Nordlicht AG',
                                    email: 'kai@example.com', phone: '+49 30 5550100', notes: 'Nur dienstags im Haus.'),
        south_kai: person_in(south, name: 'Kai Kontakt', salutation: 'Herr', function: 'Vertrieb', company: 'Nordlicht AG',
                                    email: 'kai@example.com', phone: nil, notes: 'Zahlt immer puenktlich.'),
        north_only: person_in(north, name: 'Nora Nord', function: 'Leitung IT', company: 'Hosting AG',
                                     email: 'nora@example.com', phone: '+49 30 5550199', notes: 'Bitte nicht vor zehn anrufen.'),
        north_row: person_in(north, user: shared, name: 'Mara Mitglied', function: 'Beraterin', email: 'mara.lager@example.com',
                                    phone: '+49 30 5550111')
      }
    end
  end
  let!(:merge) do
    create(:person_group, owner: user).tap do |group|
      create(:person_group_entry, person_group: group, organisation: north, person_id: people[:north_kai].id)
      create(:person_group_entry, person_group: group, organisation: south, person_id: people[:south_kai].id)
    end
  end

  let(:frame_headers) { { 'Turbo-Frame' => AllPeopleController::CARD_FRAME_ID } }
  let(:kai) { "#{north.id}:person:#{people[:north_kai].id}" }
  let(:kai_south) { "#{south.id}:person:#{people[:south_kai].id}" }
  let(:nora) { "#{north.id}:person:#{people[:north_only].id}" }
  let(:mara) { "#{north.id}:person:#{people[:north_row].id}" }

  before { sign_in user }

  after { ActsAsTenant.current_tenant = nil }

  # The lane's own answer: the frame alone.
  def lane(address, **params)
    get all_people_path(card: address, **params), headers: frame_headers
    Nokogiri::HTML(response.body)
  end

  def card(address, **params)
    doc = lane(address, **params)
    expect(response).to have_http_status(:ok)
    doc.at_css('[data-all-people-card]').tap { |element| expect(element).to be_present }
  end

  def field(card, key)
    card.at_css(%([data-card-field="#{key}"]))
  end

  # A field as the card shows it: [[text, [the organisations named at it]], ...].
  def shown(card, key)
    field(card, key).css('[data-card-value]').map do |value|
      [value.at_css('[data-card-text]').text.strip, value.css('[data-organisation-chip]').map { |chip| chip.at_css('.organisation-chip__name').text.strip }]
    end
  end

  def chips(node)
    node.css('[data-card-value] [data-organisation-chip]')
  end

  def pencils(node)
    node.css('[data-card-value] a[data-card-pencil]').map { |link| link['href'] }
  end

  def take_right_to_write(organisation)
    Prosopite.pause do
      take_people_right(user, organisation)
      ActsAsTenant.with_tenant(organisation) do
        role = Membership.find_by!(user: user, organisation: organisation).role
        create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
      end
    end
  end

  describe 'the lane' do
    it 'answers a request of the lane frame with the card alone: no layout, no list' do
      get all_people_path(card: kai), headers: frame_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to start_with(%(<turbo-frame id="#{AllPeopleController::CARD_FRAME_ID}">))
      expect(response.body).to include('Kai Kontakt', 'Einkauf', 'Vertrieb')
      expect(response.body).not_to include('<html', 'data-all-people-row', 'Nora Nord', 'all-people-search')
    end

    it 'renders the page with the lane open for the same address without the header' do
      get all_people_path(card: kai)
      doc = Nokogiri::HTML(response.body)

      expect(response).to have_http_status(:ok)
      wrapper = doc.at_css('[data-all-people]')
      expect(wrapper['class']).to include('show-content')
      expect(wrapper['data-layout-toggle-unresolved-selection-value']).to be_nil
      expect(doc.at_css("turbo-frame##{AllPeopleController::CARD_FRAME_ID} [data-all-people-card]")).to be_present
      # The list stays beside it, and the row of the open person is marked.
      expect(doc.css('tr[data-all-people-row]').size).to eq(4)
      open_row = doc.css('tr.selected-row')
      expect(open_row.size).to eq(1)
      expect(open_row.first.at_css('.all-people-row__name').text.strip).to eq('Kai Kontakt')
    end

    it 'opens the same card from any source of a merged person' do
      first = card(kai).to_html
      second = card(kai_south).to_html

      expect(second).to eq(first)
      expect(first).to include('Einkauf', 'Vertrieb')
    end

    # The row carries one address, its first source's, on every draw of the list: the
    # search redraws the rows without the card. An address that names the person by
    # another source is renamed to the row's in the bar (layout-toggle, the same history
    # entry), so the mark survives the next search and a click on the row closes the lane.
    it 'marks the row of the person on the page, whichever source the address names, and renames the address to the row\'s' do
      get all_people_path(card: kai_south)
      doc = Nokogiri::HTML(response.body)

      open_row = doc.css('tr.selected-row').sole
      expect(open_row.at_css('.all-people-row__name').text.strip).to eq('Kai Kontakt')
      expect(open_row['data-list-row-id-value']).to eq(kai)
      expect(JSON.parse(doc.at_css('[data-all-people]')['data-layout-toggle-renamed-selection-value'])).to eq('card' => [kai_south, kai])

      get all_people_path(card: kai)
      expect(Nokogiri::HTML(response.body).at_css('[data-all-people]')['data-layout-toggle-renamed-selection-value']).to be_nil
    end

    # Narrowed to one organisation, the row of a merged person holds that organisation's
    # source only: the address takes that one, not the first source of the card.
    it 'renames the address to the source the row of a narrowed list carries' do
      get all_people_path(card: kai, org: south.id)
      doc = Nokogiri::HTML(response.body)

      open_row = doc.css('tr.selected-row').sole
      expect(open_row['data-list-row-id-value']).to eq(kai_south)
      expect(JSON.parse(doc.at_css('[data-all-people]')['data-layout-toggle-renamed-selection-value'])).to eq('card' => [kai, kai_south])
    end

    it 'makes every row an opener of its card: the lane address of the row, in the lane frame' do
      get all_people_path
      doc = Nokogiri::HTML(response.body)

      row = doc.css('tr[data-all-people-row]').find { |one| one.at_css('.all-people-row__name').text.strip == 'Nora Nord' }
      expect(row['data-controller']).to eq('list-row')
      expect(row['data-list-row-param-value']).to eq('card')
      expect(row['data-list-row-id-value']).to eq(nora)
      expect(row['data-list-row-url-value']).to eq(all_people_path(card: nora))
      expect(row['data-list-row-frame-value']).to eq(AllPeopleController::CARD_FRAME_ID)
      expect(row['tabindex']).to eq('0')
      expect(doc.at_css('[data-all-people]')['class']).not_to include('show-content')
    end

    it 'keeps the tick and the menu of a row out of the row click' do
      get all_people_path
      doc = Nokogiri::HTML(response.body)

      row = doc.css('tr[data-all-people-row]').find { |one| one.at_css('.all-people-row__name').text.strip == 'Kai Kontakt' }
      expect(row.at_css('input[type="checkbox"]').ancestors('.no-click')).not_to be_empty
      expect(row.at_css('details.more-menu').ancestors('.no-click')).not_to be_empty
    end

    describe 'an address that names nothing' do
      let(:stranger_organisation) { create(:organisation, name: 'West KG') }
      let(:foreign) { person_in(stranger_organisation, name: 'Wanda West', phone: 'secret') }

      # The same request for one address after the other is the spec's doing, not a read
      # per row: the first one is watched, the rest are not.
      def missing_body(address, watched: false)
        request = -> { get all_people_path(card: address), headers: frame_headers }
        watched ? request.call : Prosopite.pause(&request)
        expect(response).to have_http_status(:not_found)
        response.body
      end

      it 'answers an unknown, a foreign, an invisible and a malformed address with the same body' do
        Prosopite.pause { take_people_right(user, south) }
        unknown = missing_body("#{north.id}:person:#{SecureRandom.uuid}", watched: true)

        expect(unknown).to start_with(%(<turbo-frame id="#{AllPeopleController::CARD_FRAME_ID}">))
        expect(unknown).to include(I18n.t('views.all_people.card.missing_title'))
        expect(unknown).not_to include('data-all-people-card=')
        [
          "#{stranger_organisation.id}:person:#{foreign.id}",   # an organisation that is not the viewer's
          "#{north.id}:person:#{foreign.id}",                   # a row of another organisation under this one
          kai_south,                                            # an organisation without the people right
          "#{north.id}:member:#{SecureRandom.uuid}",
          "#{north.id}:person:oops", "#{north.id}:new", 'oops', ':', "#{north.id}:"
        ].each do |address|
          expect(missing_body(address)).to eq(unknown), "expected the one answer for #{address}"
        end
        # The same viewer gets the card for an address that names a person.
        expect(Prosopite.pause { card(kai) }.text).to include('Kai Kontakt')
      end

      # Review of #197: a row click writes the address and marks the row before the answer
      # comes; a person deleted in between left an open lane without its cross.
      it 'gives the one answer the cross of the lane, so the lane can be closed' do
        lane("#{north.id}:person:#{SecureRandom.uuid}")

        expect(response).to have_http_status(:not_found)
        close = Nokogiri::HTML(response.body).at_css('[data-lane-head] button[data-lane-close]')
        expect(close['data-action']).to eq('click->layout-toggle#closeContent')
      end

      it 'takes a list or a hash in place of the address for the same nothing' do
        get all_people_path, params: { card: [kai] }, headers: frame_headers
        expect(response).to have_http_status(:not_found)

        get all_people_path, params: { card: { id: kai } }, headers: frame_headers
        expect(response).to have_http_status(:not_found)
      end

      it 'renders the list on a full visit and names the parameter as unresolved' do
        missing = "#{north.id}:person:#{SecureRandom.uuid}"

        get all_people_path(card: missing)
        doc = Nokogiri::HTML(response.body)

        expect(response).to have_http_status(:ok)
        wrapper = doc.at_css('[data-all-people]')
        expect(wrapper['class']).not_to include('show-content')
        expect(JSON.parse(wrapper['data-layout-toggle-unresolved-selection-value'])).to eq('card' => missing)
        expect(doc.at_css('[data-all-people-card]')).to be_nil
        expect(doc.css('tr[data-all-people-row]').size).to eq(4)
        expect(doc.css('tr.selected-row')).to be_empty
      end
    end

    it 'leaves the organisation of the session where it was' do
      Prosopite.pause { get organisation_people_path(north) }
      expect(session[:current_organisation_id]).to eq(north.id)

      get all_people_path(card: kai_south), headers: frame_headers
      expect(response.body).to include('Kai Kontakt')
      expect(session[:current_organisation_id]).to eq(north.id)

      get all_people_path(card: kai_south)
      expect(session[:current_organisation_id]).to eq(north.id)
    end

    it 'leaves no tenant behind, also after a request that raised' do
      get all_people_path(card: kai), headers: frame_headers
      expect(response.body).to include('Kai Kontakt')
      expect(ActsAsTenant.current_tenant).to be_nil

      allow(People::Lookup).to receive(:card).and_raise(ArgumentError, 'broken card')
      expect { get all_people_path(card: kai), headers: frame_headers }.to raise_error(ArgumentError, 'broken card')
      expect(ActsAsTenant.current_tenant).to be_nil
    end

    it 'names no parameter organisation_id in any address or field of the page and of the lane' do
      [-> { get all_people_path(card: kai, editing: 1) },
       -> { get all_people_path(card: kai, editing: 1), headers: frame_headers }].each do |request|
        Prosopite.pause(&request)
        doc = Nokogiri::HTML(response.body)
        addresses = doc.css('[href], [action], [src], [data-list-row-url-value]').flat_map do |node|
          %w[href action src data-list-row-url-value].filter_map { |name| node[name] }
        end

        expect(addresses).to include(a_string_including("card=#{CGI.escape(kai)}"))
        expect(addresses.grep(/organisation_id/)).to be_empty
        expect(doc.css('input, select, textarea, button').filter_map { |node| node['name'] }.grep(/organisation_id/)).to be_empty
      end
    end

    it 'draws no assistant trigger and no assistant context, on the page and in the lane' do
      allow(ChatPolicy).to receive(:assistant_gate_open?).and_return(true)
      Prosopite.pause { get organisation_people_path(north) }
      expect(response.body).to include('data-controller="assistant-trigger"')

      [-> { get all_people_path(card: kai) }, -> { get all_people_path(card: kai), headers: frame_headers }].each do |request|
        Prosopite.pause(&request)
        expect(response.body).to include('Nur dienstags im Haus.')
        expect(response.body).not_to include('id="assistant_panel"', 'data-controller="assistant-panel"',
                                             'data-controller="assistant-trigger"', 'data-assistant-context')
      end
    end

    it 'reads the organisations once for the page and its card' do
      allow(People::Directory).to receive(:new).and_call_original

      get all_people_path(card: kai)

      expect(response.body).to include('data-all-people-card')
      expect(People::Directory).to have_received(:new).twice
    end
  end

  describe 'the sources' do
    it 'shows no chip on the card of a person of one organisation, also with the switch on' do
      quiet = card(nora)
      expect(shown(quiet, :phone)).to eq([['+49 30 5550199', []]])
      expect(chips(quiet)).to be_empty
      expect(quiet.text).to include('Leitung IT', 'nora@example.com')

      user.preference_store.remember_people_card_sources(true)
      expect(chips(card(nora))).to be_empty
    end

    it 'names the organisation only at the fields whose sources differ' do
      merged = card(kai)

      # Two values, each with its source.
      expect(shown(merged, :function)).to eq([['Einkauf', ['Nord GmbH']], ['Vertrieb', ['Sued AG']]])
      # A value one source lacks is a difference: the south is named as the one without it.
      expect(shown(merged, :phone)).to eq([['+49 30 5550100', ['Nord GmbH']],
                                           [I18n.t('views.all_people.card.missing_value'), ['Sued AG']]])
      # Equal everywhere: the value alone.
      expect(shown(merged, :company)).to eq([['Nordlicht AG', []]])
      expect(shown(merged, :email)).to eq([['kai@example.com', []]])
      expect(shown(merged, :salutation)).to eq([['Herr', []]])
      # The name stands in the head; equal names are no line of their own.
      expect(field(merged, :name)).to be_nil
    end

    it 'names the organisation at every value with the switch on' do
      user.preference_store.remember_people_card_sources(true)
      merged = card(kai)

      expect(shown(merged, :company)).to eq([['Nordlicht AG', ['Nord GmbH', 'Sued AG']]])
      expect(shown(merged, :email)).to eq([['kai@example.com', ['Nord GmbH', 'Sued AG']]])
      expect(shown(merged, :name)).to eq([['Kai Kontakt', ['Nord GmbH', 'Sued AG']]])
      expect(shown(merged, :function)).to eq([['Einkauf', ['Nord GmbH']], ['Vertrieb', ['Sued AG']]])
      switch = merged.at_css('[data-card-sources-switch] button')
      expect(switch['aria-pressed']).to eq('true')
      # Pressed is more than the tone a hovered switch has as well (review of #197).
      expect(switch.css('i.bi').map { |icon| icon['class'] }).to eq(['bi bi-check-lg'])
    end

    # Review of #197: "Bearbeiten" names the organisations at every value already. The
    # switch beside it changed nothing on the card, and said "not pressed" while every
    # organisation was named.
    it 'names the organisation at every value while "Bearbeiten" is on, and offers no switch then' do
      merged = card(kai, editing: 1)

      expect(shown(merged, :company)).to eq([['Nordlicht AG', ['Nord GmbH', 'Sued AG']]])
      expect(shown(merged, :name)).to eq([['Kai Kontakt', ['Nord GmbH', 'Sued AG']]])
      expect(merged.at_css('[data-card-sources-switch]')).to be_nil
      expect(merged.at_css('a[data-card-edit-done]')['href']).to eq(all_people_path(card: kai))
      # Without it the head offers to turn it on.
      expect(card(kai).at_css('a[data-card-edit]')['href']).to eq(all_people_path(card: kai, editing: 1))
    end

    it 'gives every chip the recognition colour the person set for that organisation' do
      user.org_colors.set(north, '#d1fae5')
      user.org_colors.set(south, OrgColor::OFF)
      user.save!

      swatches = field(card(kai), :function).css('[data-organisation-chip] .organisation-chip__swatch').pluck('style')

      expect(swatches).to eq(['background-color: #d1fae5;', nil])
    end

    it 'shows the notes per source, folded and read only' do
      merged = card(kai)

      notes = merged.css('details[data-card-notes]')
      expect(notes.map { |one| one.at_css('summary').text.strip })
        .to eq([I18n.t('views.all_people.card.notes_from', organisation: 'Nord GmbH'),
                I18n.t('views.all_people.card.notes_from', organisation: 'Sued AG')])
      expect(notes.map { |one| one.at_css('.people-note').text.strip }).to eq(['Nur dienstags im Haus.', 'Zahlt immer puenktlich.'])
      expect(notes.pluck('open')).to eq([nil, nil])
      expect(merged.css('textarea, [contenteditable]')).to be_empty
      expect(notes.css('a')).to be_empty
    end

    it 'keeps the notes out of the list' do
      get all_people_path

      expect(response.body).to include('Kai Kontakt', 'Nora Nord')
      expect(response.body).not_to match(/dienstags|puenktlich|nicht vor zehn/)
    end

    it 'shows the newest last contact with its organisation' do
      Prosopite.pause do
        meeting_in(north, at: 40.days.ago, person: people[:north_kai])
        meeting_in(south, at: 3.days.ago, person: people[:south_kai])
      end

      line = card(kai).at_css('[data-card-last-contact]').text.squish

      expect(line).to include(I18n.t('views.organisations.people.age.days', count: 3), 'Sued AG')
      expect(line).not_to include('Nord GmbH')
    end

    it 'links every source into its organisation, out of the frame' do
      links = card(kai).css('a[data-card-source-link]')

      expect(links.pluck('href')).to eq([organisation_people_path(north, person_id: people[:north_kai].id),
                                         organisation_people_path(south, person_id: people[:south_kai].id)])
      expect(links.pluck('data-turbo-frame')).to eq(%w[_top _top])
    end

    describe 'a reference is not a right' do
      def expect_north_alone
        merged = card(kai)

        # The same answer proves the other source present.
        expect(merged.text).to include('Kai Kontakt', 'Einkauf', 'Nur dienstags im Haus.', '+49 30 5550100')
        expect(response.body).not_to include('Vertrieb', 'Zahlt immer puenktlich.', 'Sued AG', south.id)
        expect(chips(merged)).to be_empty
        expect(merged.css('a[data-card-source-link]').size).to eq(1)
      end

      it 'shows nothing of a source in an organisation whose people right was taken away' do
        expect(card(kai).text).to include('Vertrieb', 'Zahlt immer puenktlich.', 'Sued AG')

        Prosopite.pause { take_people_right(user, south) }

        expect_north_alone
      end

      # A member is on the members page too, by another right. That is no right to their
      # entry in the people directory of that organisation.
      it 'shows nothing of a member in an organisation without the people right, though the viewer sees that member there' do
        Prosopite.pause do
          take_people_right(user, south)
          ActsAsTenant.with_tenant(south) do
            project = create(:project, organisation: south)
            [user, shared].each { |account| create(:project_permission, user: account, project: project, tickets_access: :read_only) }
          end
        end
        seen_as_member = ActsAsTenant.with_tenant(south) do
          MembershipPolicy::Scope.new(User.find(user.id), Membership).resolve.exists?(user_id: shared.id, organisation_id: south.id)
        end
        expect(seen_as_member).to be(true)

        member = card(mara)

        expect(member.text).to include('Mara Mitglied', 'Beraterin', '+49 30 5550111')
        expect(member.css('a[data-card-source-link]').pluck('href')).to eq([organisation_people_path(north, person_id: people[:north_row].id)])
        expect(chips(member)).to be_empty
        expect(response.body).not_to include('Sued AG', south.id)
      end

      it 'shows nothing of a source in an organisation where the membership is deactivated' do
        Prosopite.pause { ActsAsTenant.with_tenant(south) { Membership.find_by!(user: user, organisation: south).update!(active: false) } }
        # With one organisation left there is no page above them; a third keeps it.
        Prosopite.pause { join_organisation(user, create(:organisation, name: 'West KG'), admin: true) }

        expect_north_alone
      end
    end
  end

  # Review of #197: the card showed every value as text, apart from the fixed email and
  # phone. An additional detail that the people page links (a phone, an email, a web
  # address) or writes as a date in the reader's language stood there as stored.
  describe 'the values' do
    def link(card, key)
      field(card, key).at_css('a.people-fields__link')
    end

    def detail_value(card, label)
      card.css('[data-card-field]').find { |one| one.at_css('dt').text.strip == label }.at_css('[data-card-text]')
    end

    it 'links an email and a phone number, and nothing else of the fixed fields' do
      single = card(nora)

      expect(link(single, :email)['href']).to eq('mailto:nora@example.com')
      expect(link(single, :phone)['href']).to eq('tel:+49305550199')
      expect(field(single, :company).css('a')).to be_empty
    end

    it 'escapes what would end the address in a mailto link' do
      ActsAsTenant.with_tenant(north) { people[:north_only].update_columns(email: 'nora?bcc=x@example.com') }

      expect(link(card(nora), :email)['href']).to eq('mailto:nora%3Fbcc%3Dx@example.com')
    end

    # Review of #206: a fixed email is linked as it is, as on the people page: a member's
    # is checked by the account alone, which takes what the rule for an additional email
    # (URI::MailTo::EMAIL_REGEXP) does not. No example had such an address.
    it 'links a fixed email that only the account\'s rule takes' do
      address = 'jörg@example.com'
      expect(address).to match(Devise.email_regexp)
      expect(address).not_to match(URI::MailTo::EMAIL_REGEXP)
      ActsAsTenant.with_tenant(north) { people[:north_only].update_columns(email: address) }

      expect(link(card(nora), :email)['href']).to eq('mailto:jörg@example.com')
    end

    it 'shows an additional detail as the people page does: a link by its kind, a date in the reader\'s language' do
      ActsAsTenant.with_tenant(north) do
        people[:north_only].update!(additional_details: [
                                      { 'kind' => 'date', 'label' => 'Geburtstag', 'value' => '1985-03-14' },
                                      { 'kind' => 'url', 'label' => 'Profil', 'value' => 'https://example.com/nora' },
                                      { 'kind' => 'phone', 'label' => 'Mobil', 'value' => '0171 5550100' },
                                      { 'kind' => 'email', 'label' => 'Privat', 'value' => 'nora.privat@example.com' },
                                      { 'kind' => 'text', 'label' => 'Kundennummer', 'value' => 'K-17' }
                                    ])
      end
      single = card(nora, locale: 'de')

      expect(detail_value(single, 'Geburtstag').text.strip).to eq(I18n.l(Date.new(1985, 3, 14), format: :long, locale: :de))
      profile = detail_value(single, 'Profil').at_css('a')
      expect([profile['href'], profile['target'], profile['rel']]).to eq(['https://example.com/nora', '_blank', 'noopener noreferrer'])
      expect(detail_value(single, 'Mobil').at_css('a')['href']).to eq('tel:01715550100')
      expect(detail_value(single, 'Privat').at_css('a')['href']).to eq('mailto:nora.privat@example.com')
      expect(detail_value(single, 'Kundennummer').css('a')).to be_empty
    end
  end

  describe 'the pencils' do
    it 'offers each writable source a form while editing a member with no additional values' do
      ActsAsTenant.with_tenant(north) { people[:north_row].update!(function: nil, company: nil, phone: nil) }

      member = card(mara, editing: 1)

      expect(pencils(field(member, :name))).to be_empty
      expect(pencils(field(member, :email))).to be_empty
      links = member.css('a[data-card-source-edit]')
      expect(links.pluck('href')).to eq([organisation_people_path(north, edit: people[:north_row].id),
                                         organisation_people_path(south, new: 'person', user_id: shared.id)])
      expect(links.pluck('data-turbo-frame')).to eq(%w[_top _top])
      expect(card(mara).css('a[data-card-source-edit]')).to be_empty
    end

    it 'puts a pencil into the chip of every source that leads to the form of that row in its organisation' do
      merged = card(kai)

      function = field(merged, :function)
      expect(pencils(function)).to eq([organisation_people_path(north, edit: people[:north_kai].id),
                                       organisation_people_path(south, edit: people[:south_kai].id)])
      pencil = function.at_css('a[data-card-pencil]')
      expect(pencil.ancestors('[data-organisation-chip]')).not_to be_empty
      expect(pencil['data-turbo-frame']).to eq('_top')
      expect(pencil['aria-label']).to eq(I18n.t('views.all_people.card.edit_in', organisation: 'Nord GmbH'))
      # The value the south lacks is entered there.
      expect(pencils(field(merged, :phone))).to eq([organisation_people_path(north, edit: people[:north_kai].id),
                                                    organisation_people_path(south, edit: people[:south_kai].id)])
    end

    it 'gives a source where the viewer may only read a chip without a pencil' do
      take_right_to_write(south)
      merged = card(kai, editing: 1)

      expect(shown(merged, :function)).to eq([['Einkauf', ['Nord GmbH']], ['Vertrieb', ['Sued AG']]])
      expect(pencils(field(merged, :function))).to eq([organisation_people_path(north, edit: people[:north_kai].id)])
      expect(shown(merged, :company)).to eq([['Nordlicht AG', ['Nord GmbH', 'Sued AG']]])
      expect(pencils(field(merged, :company))).to eq([organisation_people_path(north, edit: people[:north_kai].id)])
      expect(response.body).not_to include(organisation_people_path(south, edit: people[:south_kai].id))
    end

    it 'offers no "Bearbeiten" when the viewer may write in none of the organisations' do
      take_right_to_write(south)
      take_right_to_write(north)
      merged = card(kai)

      expect(merged.text).to include('Einkauf', 'Vertrieb')
      expect(merged.at_css('a[data-card-edit]')).to be_nil
      expect(pencils(merged)).to be_empty
      expect(response.body).not_to match(/[?&]edit=/)
    end

    it 'gives the name and the email of a member no pencil, and the member without a row the form that adds the details' do
      member = card(mara, editing: 1)
      new_form = organisation_people_path(south, new: Organisations::PeopleController::NEW_STATE, user_id: shared.id)

      expect(shown(member, :name)).to eq([['Mara Mitglied', ['Nord GmbH', 'Sued AG']]])
      expect(pencils(field(member, :name))).to be_empty
      expect(shown(member, :email)).to eq([['mara@example.com', ['Nord GmbH', 'Sued AG']]])
      expect(pencils(field(member, :email))).to be_empty
      # What the row in the north holds is edited there; what the south lacks, through the form of a new row.
      expect(pencils(field(member, :function))).to eq([organisation_people_path(north, edit: people[:north_row].id), new_form])
      expect(pencils(field(member, :phone))).to eq([organisation_people_path(north, edit: people[:north_row].id), new_form])
      expect(response.body).not_to include('mara.lager@example.com')
    end

    it 'gives a member without a row no pencil where the viewer may only read' do
      take_right_to_write(south)
      Prosopite.pause do
        ActsAsTenant.with_tenant(south) do
          project = create(:project, organisation: south)
          [user, shared].each { |account| create(:project_permission, user: account, project: project, tickets_access: :read_only) }
        end
      end

      member = card(mara, editing: 1)

      expect(shown(member, :phone)).to eq([['+49 30 5550111', ['Nord GmbH']], [I18n.t('views.all_people.card.missing_value'), ['Sued AG']]])
      expect(pencils(field(member, :phone))).to eq([organisation_people_path(north, edit: people[:north_row].id)])
      expect(response.body).not_to include('new=person')
      expect(member.css('a[data-card-source-edit]').pluck('href')).to eq([organisation_people_path(north, edit: people[:north_row].id)])
      read_only = member.css('[data-card-source]').map { |one| one.text.include?(I18n.t('views.all_people.card.read_only')) }
      expect(read_only).to eq([false, true])
    end

    it 'gives the notes no pencil' do
      merged = card(kai, editing: 1)

      expect(merged.css('details[data-card-notes]').size).to eq(2)
      expect(merged.css('details[data-card-notes] a')).to be_empty
    end

    it 'makes "Bearbeiten" of a person of one organisation the way into that form' do
      single = card(nora)

      edit = single.at_css('a[data-card-edit]')
      expect(edit['href']).to eq(organisation_people_path(north, edit: people[:north_only].id))
      expect(edit['data-turbo-frame']).to eq('_top')
      expect(single.at_css('[data-card-sources-switch]')).to be_nil
    end
  end

  describe 'the menu of the card' do
    def menu(card)
      card.at_css('[data-lane-head] details.more-menu')
    end

    def takeover_links(card)
      card.css('[data-lane-head] details.more-menu a[data-card-takeover]')
    end

    # The dialog opened from the card: every answer leads back to a card on this page.
    def takeover_path(organisation, person)
      new_organisation_person_takeover_path(organisation, person, from: Organisations::PersonTakeoversController::FROM_ALL_PEOPLE)
    end

    it 'offers the takeover for every source that is a contact without an account, into the frame of its dialog' do
      merged = card(kai)

      links = takeover_links(merged)
      expect(links.pluck('href')).to eq([takeover_path(north, people[:north_kai]), takeover_path(south, people[:south_kai])])
      expect(links.pluck('data-turbo-frame')).to eq(["person-takeover-modal-#{people[:north_kai].id}",
                                                     "person-takeover-modal-#{people[:south_kai].id}"])
      expect(links.map { |link| link.text.strip })
        .to eq([I18n.t('views.all_people.card.takeover_from', organisation: 'Nord GmbH'),
                I18n.t('views.all_people.card.takeover_from', organisation: 'Sued AG')])
      # The frame each dialog loads into stands on the card.
      frames = merged.css('turbo-frame[id^="person-takeover-modal-"]')
      expect(frames.pluck('id')).to eq(["person-takeover-modal-#{people[:north_kai].id}", "person-takeover-modal-#{people[:south_kai].id}"])
      # Each of them returns the focus to the one "···" button of the card. Until the review
      # of #197 the button carried the id of the first contact only, and the dialog of the
      # second one returned the focus to an id that is on no page.
      trigger = menu(merged).at_css('summary')
      expect(trigger['id']).to eq(AllPeopleHelper::CARD_MORE_ACTIONS_ID)
      expect(frames.pluck('data-person-takeover-return-id')).to eq([trigger['id']] * 2)
    end

    it 'names no organisation in the takeover of a person of one organisation' do
      single = card(nora)

      expect(takeover_links(single).map { |link| link.text.strip }).to eq([I18n.t('views.organisations.people.takeover.menu')])
      expect(takeover_links(single).pluck('href')).to eq([takeover_path(north, people[:north_only])])
    end

    it 'offers no takeover without somewhere to take the contact' do
      take_right_to_write(south)
      merged = card(kai)

      # From the north there is nowhere to go; from the south there is.
      expect(takeover_links(merged).pluck('href')).to eq([takeover_path(south, people[:south_kai])])
      expect(response.body).not_to include(new_organisation_person_takeover_path(north, people[:north_kai]))
    end

    it 'offers no takeover for a member, and no menu at all when there is nothing in it' do
      member = card(mara)

      expect(member.text).to include('Mara Mitglied')
      expect(menu(member)).to be_nil
      expect(response.body).not_to include('person-takeover-modal-', 'takeover/new')
    end

    it 'offers to undo the merge, back to the card' do
      split = menu(card(kai)).at_css('form[data-card-split]')

      expect(split['action']).to eq(all_people_merge_path(merge.id, card: kai))
      expect(split.at_css('input[name="_method"]')['value']).to eq('delete')
      expect(split['data-turbo-frame']).to eq('_top')
      expect(split['data-turbo-confirm']).to eq(I18n.t('views.confirm.split_merged_person', name: 'Kai Kontakt'))
      # Two sources: taking one out is undoing the merge, so that is the one offer.
      expect(menu(card(kai)).css('form[data-card-detach]')).to be_empty
    end

    it 'offers to take one source out of a merge of three' do
      west = create(:organisation, name: 'West KG')
      west_kai = nil
      Prosopite.pause do
        join_organisation(user, west, admin: true)
        west_kai = person_in(west, name: 'Kai Kontakt', email: nil)
        create(:person_group_entry, person_group: merge, organisation: west, person_id: west_kai.id)
      end

      forms = menu(card(kai)).css('form[data-card-detach]')

      # The way back is the card of the person that stays merged: a source that is not the
      # one leaving. For the first source that is the second one.
      expect(forms.pluck('action')).to eq(
        [[north, people[:north_kai], kai_south], [south, people[:south_kai], kai], [west, west_kai, kai]].map do |organisation, person, back|
          all_people_merge_path(merge.id, source: "#{organisation.id}:person:#{person.id}", card: back)
        end
      )
      expect(forms.map { |form| form.at_css('button').text.strip })
        .to eq(['Nord GmbH', 'Sued AG', 'West KG'].map { |name| I18n.t('views.all_people.card.detach', organisation: name) })
      expect(forms.pluck('data-turbo-confirm').uniq.size).to eq(3)
      expect(forms.pluck('data-turbo-frame').uniq).to eq(['_top'])
    end

    it 'offers no undo for a person the same account alone joins' do
      member = card(mara)

      expect(member.css('a[data-card-source-link]').size).to eq(2)
      expect(member.css('form[data-card-split], form[data-card-detach]')).to be_empty
    end

    it 'carries the current page in both forms that take a merge apart' do
      west = create(:organisation, name: 'West KG')
      Prosopite.pause do
        join_organisation(user, west, admin: true)
        extra = person_in(west, name: 'Kai Kontakt')
        create(:person_group_entry, person_group: merge, organisation: west, person_id: extra.id)
      end

      forms = card(kai, page: 2).css('form[data-card-split], form[data-card-detach]')

      expect(forms.size).to eq(4)
      expect(forms.map { |form| Rack::Utils.parse_nested_query(URI.parse(form['action']).query)['page'] }).to eq(%w[2 2 2 2])
    end
  end

  describe 'the switch' do
    it 'is stored for the person, survives a reload, and is taken back the same way' do
      expect(chips(field(card(kai), :company))).to be_empty

      patch all_people_sources_path, params: { show: '1', card: kai }

      expect(response).to redirect_to(all_people_path(card: kai))
      expect(response).to have_http_status(:see_other)
      expect(User.find(user.id).preferences['people_card_sources']).to be(true)
      # A reload, and any other card: the organisations stand at every value.
      expect(chips(field(card(kai), :company)).size).to eq(2)
      get all_people_path(card: kai)
      expect(chips(field(Nokogiri::HTML(response.body), :company)).size).to eq(2)

      patch all_people_sources_path, params: { show: '0', card: kai }

      expect(User.find(user.id).preferences['people_card_sources']).to be(false)
      expect(chips(field(card(kai), :company))).to be_empty
    end

    it 'belongs to the person: another one keeps their own' do
      other = create(:user)
      Prosopite.pause do
        join_organisation(other, north, rights: ['view_people'])
        join_organisation(other, south, rights: ['view_people'])
      end

      patch all_people_sources_path, params: { show: '1', card: kai }

      expect(User.find(other.id).preference_store.people_card_sources?).to be(false)
      expect(User.find(user.id).preference_store.people_card_sources?).to be(true)
    end

    it 'sends its state and the open card with the button, inside the lane frame' do
      form = card(kai).at_css('form[data-card-sources-switch]')

      expect(form['action']).to eq(all_people_sources_path)
      expect(form.at_css('input[name="_method"]')['value']).to eq('patch')
      expect(form.at_css('input[name="show"]')['value']).to eq('1')
      expect(form.at_css('input[name="card"]')['value']).to eq(kai)
      expect(form['data-turbo-frame']).to be_nil
      expect(form.at_css('button')['aria-pressed']).to eq('false')
      expect(form.css('button i.bi').map { |icon| icon['class'] }).to eq(['bi bi-building'])
    end

    it 'goes back to the card it came from, as the card alone names it' do
      patch all_people_sources_path, params: { show: '1', card: kai, editing: '1' }

      expect(response).to redirect_to(all_people_path(card: kai))
    end

    it 'stores a real boolean whatever the request sends, and goes back to the list without a card' do
      patch all_people_sources_path, params: { show: 'yes please', card: ['x'] }

      expect(response).to redirect_to(all_people_path)
      expect(User.find(user.id).preferences['people_card_sources']).to be(true)

      patch all_people_sources_path, params: { show: { a: 1 } }
      expect(User.find(user.id).preferences['people_card_sources']).to be(false)
    end

    it 'never moves the organisation of the session and leaves no tenant behind' do
      Prosopite.pause { get organisation_people_path(north) }

      patch all_people_sources_path, params: { show: '1', card: kai_south }

      expect(session[:current_organisation_id]).to eq(north.id)
      expect(ActsAsTenant.current_tenant).to be_nil
    end

    it 'asks for a session' do
      sign_out user

      patch all_people_sources_path, params: { show: '1', card: kai }

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  # The card shares two partials with other pages. What those pages draw stays as it was
  # before the card learnt its modes (the markup is pinned as the base rendered it).
  describe 'the partials the card shares' do
    let(:chip_action) { { url: '/org/1/people?edit=2', label: 'In Nord GmbH bearbeiten', data: { card_pencil: true } } }

    def chip(**locals)
      ApplicationController.render(partial: 'shared/organisation_chip', locals: { name: 'Nord GmbH', **locals })
    end

    it 'renders the identity of a person on the people page of an organisation as before' do
      Prosopite.pause { get organisation_people_path(north, person_id: people[:north_only].id) }
      contact = Nokogiri::HTML(response.body).at_css('.people-identity').to_html
      Prosopite.pause { get organisation_people_path(north, member_id: user.id) }
      member = Nokogiri::HTML(response.body).at_css('.people-identity').to_html

      expect(contact).to eq("<div class=\"people-identity\">\n  <span class=\"relative inline-flex items-center justify-center shrink-0 neo-user-avatar rounded-[5px] bg-cream-200 border border-cream-300 font-bold text-cream-900 w-[52px] h-[52px] text-[15px] people-avatar people-avatar--contact\" data-controller=\"avatar-fallback\">NN</span>\n  <div class=\"people-identity__text\">\n    <h2 class=\"people-identity__name\">Nora Nord</h2>\n    <p class=\"people-identity__line\">Kontakt · Hosting AG</p>\n  </div>\n</div>")
      expect(member).to eq("<div class=\"people-identity\">\n  <span class=\"relative inline-flex items-center justify-center shrink-0 neo-user-avatar rounded-[5px] bg-cream-200 border border-cream-300 font-bold text-cream-900 w-[52px] h-[52px] text-[15px] people-avatar \" title=\"Vera Viewer\" data-controller=\"avatar-fallback\">VV</span>\n  <div class=\"people-identity__text\">\n    <h2 class=\"people-identity__name\">Vera Viewer</h2>\n    <p class=\"people-identity__line\">Mitglied</p>\n  </div>\n</div>")
    end

    it 'renders the plain chip and the chip with a pencil as before' do
      expect(chip(color: '#d1fae5')).to eq("  <span class=\"organisation-chip\" title=\"Nord GmbH\" data-organisation-chip=\"true\"><span class=\"organisation-chip__swatch\" aria-hidden=\"true\" style=\"background-color: #d1fae5;\"></span><span class=\"organisation-chip__name\">Nord GmbH</span></span>\n")
      expect(chip).to eq("  <span class=\"organisation-chip\" title=\"Nord GmbH\" data-organisation-chip=\"true\"><span class=\"organisation-chip__swatch\" aria-hidden=\"true\"></span><span class=\"organisation-chip__name\">Nord GmbH</span></span>\n")
      expect(chip(color: '#d1fae5', action: chip_action)).to eq("  <span class=\"organisation-chip organisation-chip--action\" data-organisation-chip=\"true\">\n    <span class=\"organisation-chip__swatch\" aria-hidden=\"true\" style=\"background-color: #d1fae5;\"></span><span class=\"organisation-chip__name\">Nord GmbH</span>\n    <a class=\"organisation-chip__action\" title=\"In Nord GmbH bearbeiten\" aria-label=\"In Nord GmbH bearbeiten\" data-turbo-frame=\"_top\" data-card-pencil=\"true\" href=\"/org/1/people?edit=2\">\n      <i class=\"bi bi-pencil\" aria-hidden=\"true\"></i>\n</a></span>")
    end

    it 'makes the whole chip one link into its organisation, out of the frame, named by its label' do
      link = Nokogiri::HTML.fragment(chip(url: '/org/1/people', label: 'In Nord GmbH öffnen')).at_css('a')

      expect([link['href'], link['data-turbo-frame'], link['aria-label'], link['title']])
        .to eq(['/org/1/people', '_top', 'In Nord GmbH öffnen', 'In Nord GmbH öffnen'])
      expect(link['class']).to eq('organisation-chip organisation-chip--link')
      expect(link.key?('data-organisation-chip')).to be(true)
      expect(link.at_css('.organisation-chip__name').text).to eq('Nord GmbH')
    end

    it 'puts the pencil beside the link of the name, never a link inside a link' do
      node = Nokogiri::HTML.fragment(chip(url: '/org/1/people', label: 'In Nord GmbH öffnen', action: chip_action)).at_css('[data-organisation-chip]')

      expect(node.name).to eq('span')
      expect(node.css('a').map { |link| [link['class'], link['href']] })
        .to eq([['organisation-chip__link', '/org/1/people'], ['organisation-chip__action', '/org/1/people?edit=2']])
      expect(node.css('a a')).to be_empty
    end

    it 'gives a chip with a hint the hint as its title and for a screen reader, and no pencil' do
      node = Nokogiri::HTML.fragment(chip(url: '/org/1/people', label: 'In Nord GmbH öffnen', hint: 'Nur lesen')).at_css('[data-organisation-chip]')

      expect([node.name, node['title']]).to eq(['span', 'Nur lesen'])
      expect(node.at_css('.sr-only').text).to eq('Nur lesen')
      expect(node.css('a').map { |link| link['href'] }).to eq(['/org/1/people'])
      expect(node.css('.organisation-chip__action')).to be_empty
    end
  end
end
