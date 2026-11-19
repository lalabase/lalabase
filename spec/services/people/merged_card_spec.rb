# frozen_string_literal: true

require 'rails_helper'

# What: People::MergedCard, the card of one person of the people list above the
#   organisations: the values of every source the viewer may read, side by side, each
#   with the organisations it comes from.
# Type: Service spec against real rows in two (and three) organisations.
# Why:  the card shows contact details and notes of several tenants at once. Pinned here:
#   what counts as one value and what as a difference, who gets an address to edit, what
#   a source without the right contributes (nothing), and that every row is read under
#   the tenant of its organisation and leaves as a plain value.
RSpec.describe People::MergedCard, :ci_guard do
  include AllPeopleHelpers

  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }
  let(:west) { create(:organisation, name: 'West KG') }
  let(:viewer) { create(:user, first_name: 'Vera', last_name: 'Viewer', email: 'vera@example.com') }
  let(:shared) { create(:user, first_name: 'Mara', last_name: 'Mitglied', email: 'mara@example.com') }

  # South first on purpose: the order of the sources is the order of the organisations'
  # names, never the order of creation by accident.
  before do
    Prosopite.pause do
      join_organisation(viewer, south, admin: true)
      join_organisation(viewer, north, admin: true)
    end
  end

  after { ActsAsTenant.current_tenant = nil }

  let!(:north_kai) do
    person_in(north, name: 'Kai Kontakt', salutation: 'Herr', function: 'Einkauf', company: 'Nordlicht AG',
                     email: 'kai@example.com', phone: '+49 30 5550100', notes: 'Nur dienstags im Haus.')
  end
  let!(:south_kai) do
    person_in(south, name: 'Kai Kontakt', salutation: 'Herr', function: 'Vertrieb', company: 'Nordlicht AG',
                     email: 'kai@example.com', phone: nil, notes: 'Zahlt immer puenktlich.')
  end

  def merge_of(owner, *entries)
    create(:person_group, owner: owner).tap do |group|
      entries.each { |organisation, address| create(:person_group_entry, person_group: group, organisation: organisation, **address) }
    end
  end

  def address_of(organisation, person: nil, member: nil)
    "#{organisation.id}:#{person ? "person:#{person.id}" : "member:#{member.id}"}"
  end

  # A fresh account object per read, as a request has one.
  def card_at(address)
    described_class.call(viewer: User.find(viewer.id), address: address)
  end

  def field(card, key)
    card.fields.find { |one| one.key == key }
  end

  # The values of a field as [text, the names of the organisations it comes from].
  def values(card, key)
    names = card.sources.to_h { |source| [source.organisation_id, source.organisation_name] }
    field(card, key).values.map { |value| [value.text, value.sources.map { |source| names.fetch(source.organisation_id) }] }
  end

  def source(card, organisation)
    card.sources.find { |one| one.organisation_id == organisation.id }
  end

  # Every value the result holds, records and plain values alike.
  def leaves(value)
    case value
    when Data then value.to_h.values.flat_map { |inner| leaves(inner) }
    when Hash then value.values.flat_map { |inner| leaves(inner) }
    when Array then value.flat_map { |inner| leaves(inner) }
    else [value]
    end
  end

  describe 'a merged person' do
    let!(:merge) { merge_of(viewer, [north, { person_id: north_kai.id }], [south, { person_id: south_kai.id }]) }
    let(:card) { card_at(address_of(north, person: north_kai)) }

    it 'names the person by the first source and lists the sources in the order of the organisations' do
      expect(card.name).to eq('Kai Kontakt')
      expect(card.kind).to eq('contact')
      expect(card.sources.map(&:organisation_name)).to eq(['Nord GmbH', 'Sued AG'])
      expect(card.address).to eq(address_of(north, person: north_kai))
      expect(card.merge_id).to eq(merge.id)
    end

    it 'shows a value that is equal in every source as one line with all sources, and no difference' do
      expect(values(card, :company)).to eq([['Nordlicht AG', ['Nord GmbH', 'Sued AG']]])
      expect(field(card, :company).differs).to be(false)
      expect(values(card, :email)).to eq([['kai@example.com', ['Nord GmbH', 'Sued AG']]])
      expect(field(card, :name).differs).to be(false)
    end

    it 'shows two values with the source of each, and says that they differ' do
      expect(values(card, :function)).to eq([['Einkauf', ['Nord GmbH']], ['Vertrieb', ['Sued AG']]])
      expect(field(card, :function).differs).to be(true)
    end

    # D12: what a source lacks is said per source (Card#holdings), not as a value of the
    # field: a value without a text buried the values of a person of seven organisations.
    it 'counts a value one source lacks as a difference, and lists no value without a text' do
      expect(values(card, :phone)).to eq([['+49 30 5550100', ['Nord GmbH']]])
      expect(field(card, :phone).differs).to be(true)
      expect(card.fields.flat_map(&:values).map(&:text)).to all(be_present)
    end

    it 'leads with the source that has the most values' do
      expect(card.lead).to eq(north.id)
    end

    # D11: the lead's values come first in a field, as the lead wrote them, and the label of
    # a detail as the lead wrote it. The order of the sources and the name, kind and address
    # of the card stay the first source's.
    it 'puts the values of the lead first, as the lead wrote them, also when the lead is not the first source' do
      ActsAsTenant.with_tenant(north) do
        north_kai.update_columns(additional_details: [{ 'kind' => 'phone', 'label' => 'mobil', 'value' => '0171 1' }])
      end
      ActsAsTenant.with_tenant(south) do
        south_kai.update_columns(phone: '+49 40 5550100', department: 'Vertrieb', email: 'KAI@Example.com',
                                 additional_details: [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '0171 2' }])
      end

      expect(card.lead).to eq(south.id)
      expect(values(card, :function)).to eq([['Vertrieb', ['Sued AG']], ['Einkauf', ['Nord GmbH']]])
      expect(values(card, :email)).to eq([['KAI@Example.com', ['Sued AG', 'Nord GmbH']]])
      expect(values(card, :phone)).to eq([['+49 40 5550100', ['Sued AG']], ['+49 30 5550100', ['Nord GmbH']]])
      mobile = card.fields.find { |one| one.key.to_s.start_with?('detail:') }
      expect([mobile.label, mobile.values.map(&:text)]).to eq(['Mobil', ['0171 2', '0171 1']])
      expect([card.name, card.kind, card.address]).to eq(['Kai Kontakt', 'contact', address_of(north, person: north_kai)])
      expect(card.sources.map(&:organisation_name)).to eq(['Nord GmbH', 'Sued AG'])
    end

    it 'lists no field that no source has a value for' do
      expect(field(card, :department)).to be_nil
    end

    it 'keeps the fields in the order of the form' do
      expect(card.fields.map(&:key)).to eq(%i[name salutation function company email phone])
    end

    it 'opens the same card from any of its sources' do
      other = card_at(address_of(south, person: south_kai))

      expect(other).to eq(card)
      expect(other.address).to eq(address_of(north, person: north_kai))
    end

    it 'takes whitespace and the case of an email for no difference, and shows the first source as written' do
      ActsAsTenant.with_tenant(north) { north_kai.update_columns(phone: '  +49 30 1 ', email: 'Kai@Example.com') }
      ActsAsTenant.with_tenant(south) { south_kai.update_columns(phone: '+49 30 1', email: 'kai@example.com') }

      expect(values(card, :phone)).to eq([['  +49 30 1 ', ['Nord GmbH', 'Sued AG']]])
      expect(values(card, :email)).to eq([['Kai@Example.com', ['Nord GmbH', 'Sued AG']]])
      expect(field(card, :phone).differs).to be(false)
      expect(field(card, :email).differs).to be(false)
    end

    # Review of #197: every whitespace went before the comparison, so "AB C" and "A BC"
    # were one value with the first spelling and both organisations at it. Only a phone
    # number is compared by its characters alone; everything else keeps its word breaks.
    it 'keeps the word breaks of anything but a phone number and an email: more spaces are none' do
      ActsAsTenant.with_tenant(north) { north_kai.update_columns(company: 'Nord Licht AG', department: ' Lager  Ost ') }
      ActsAsTenant.with_tenant(south) { south_kai.update_columns(company: 'NordLicht AG', department: 'Lager Ost') }

      expect(values(card, :company)).to eq([['Nord Licht AG', ['Nord GmbH']], ['NordLicht AG', ['Sued AG']]])
      expect(field(card, :company).differs).to be(true)
      expect(values(card, :department)).to eq([[' Lager  Ost ', ['Nord GmbH', 'Sued AG']]])
      expect(field(card, :department).differs).to be(false)
    end

    it 'compares an additional phone number without its spaces and any other detail by its words' do
      ActsAsTenant.with_tenant(north) do
        north_kai.update!(additional_details: [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '0171 5550100' },
                                               { 'kind' => 'text', 'label' => 'Kundennummer', 'value' => 'K 17' }])
      end
      ActsAsTenant.with_tenant(south) do
        south_kai.update!(additional_details: [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '01715550100' },
                                               { 'kind' => 'text', 'label' => 'Kundennummer', 'value' => 'K17' }])
      end

      expect(card.fields.find { |one| one.label == 'Mobil' }.differs).to be(false)
      expect(card.fields.find { |one| one.label == 'Kundennummer' }.values.map(&:text)).to eq(['K 17', 'K17'])
    end

    # Review of #206: the rule hung at the kind of each entry. One label typed as a phone
    # number in one organisation and as text in the other gave the same words twice, each
    # with one organisation, and which source came first decided the answer. A field has
    # one rule: a phone number's, or an email's, as soon as one source says it is one.
    [%w[phone email text text], %w[text text phone email]].each do |north_phone, north_mail, south_phone, south_mail|
      it "compares the values of one label by one rule when the organisations gave it different kinds (first: #{north_phone})" do
        ActsAsTenant.with_tenant(north) do
          north_kai.update!(additional_details: [{ 'kind' => north_phone, 'label' => 'Mobil', 'value' => '0171 5550100' },
                                                 { 'kind' => north_mail, 'label' => 'Privat', 'value' => 'Kai@Example.com' }])
        end
        ActsAsTenant.with_tenant(south) do
          south_kai.update!(additional_details: [{ 'kind' => south_phone, 'label' => 'Mobil', 'value' => '01715550100' },
                                                 { 'kind' => south_mail, 'label' => 'Privat', 'value' => 'kai@example.com' }])
        end
        mobile, private_mail = %w[Mobil Privat].map { |label| card.fields.find { |one| one.label == label } }

        expect(values(card, mobile.key)).to eq([['0171 5550100', ['Nord GmbH', 'Sued AG']]])
        expect(values(card, private_mail.key)).to eq([['Kai@Example.com', ['Nord GmbH', 'Sued AG']]])
        expect([mobile.differs, private_mail.differs]).to eq([false, false])
        expect(mobile.values.map(&:kind)).to eq([north_phone])
      end
    end

    # Review of #206, round 2: an email's rule comes before a phone number's. With the
    # order turned, a label one organisation keeps as an email and another as a phone
    # number was compared with its case again. No example had both kinds at one label.
    it 'takes the rule of an email before that of a phone number when one label has both kinds' do
      ActsAsTenant.with_tenant(north) do
        north_kai.update_columns(additional_details: [{ 'kind' => 'email', 'label' => 'Kontakt', 'value' => 'Kai1@Example.com' }])
      end
      ActsAsTenant.with_tenant(south) do
        south_kai.update_columns(additional_details: [{ 'kind' => 'phone', 'label' => 'Kontakt', 'value' => 'kai1@example.com' }])
      end
      contact = card.fields.find { |one| one.label == 'Kontakt' }

      expect(values(card, contact.key)).to eq([['Kai1@Example.com', ['Nord GmbH', 'Sued AG']]])
      expect(contact.differs).to be(false)
    end

    it 'takes the same words for one value whatever kind each organisation gave them' do
      ActsAsTenant.with_tenant(north) do
        north_kai.update!(additional_details: [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '0171 5550100' }])
      end
      ActsAsTenant.with_tenant(south) do
        south_kai.update!(additional_details: [{ 'kind' => 'text', 'label' => 'Mobil', 'value' => '0171 5550100' }])
      end

      expect(card.fields.find { |one| one.label == 'Mobil' }.values.map(&:text)).to eq(['0171 5550100'])
    end

    it 'hands out the kind of every value, for the page to show it as the people page does' do
      ActsAsTenant.with_tenant(north) do
        north_kai.update!(additional_details: [{ 'kind' => 'date', 'label' => 'Geburtstag', 'value' => '1985-03-14' }])
      end

      expect(field(card, :phone).values.map(&:kind)).to eq(['phone'])
      expect(field(card, :email).values.map(&:kind)).to eq(['email'])
      expect(field(card, :company).values.map(&:kind)).to eq([nil])
      expect(card.fields.find { |one| one.label == 'Geburtstag' }.values.map(&:kind)).to eq(['date'])
    end

    it 'takes the case of anything but an email for a difference' do
      ActsAsTenant.with_tenant(south) { south_kai.update_columns(company: 'NORDLICHT AG') }

      expect(values(card, :company)).to eq([['Nordlicht AG', ['Nord GmbH']], ['NORDLICHT AG', ['Sued AG']]])
    end

    it 'matches the additional details by their label' do
      ActsAsTenant.with_tenant(north) do
        north_kai.update!(additional_details: [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '0171 5550100' },
                                               { 'kind' => 'text', 'label' => 'Kundennummer', 'value' => 'K-17' }])
      end
      ActsAsTenant.with_tenant(south) do
        south_kai.update!(additional_details: [{ 'kind' => 'phone', 'label' => 'mobil', 'value' => '01715550100' },
                                               { 'kind' => 'text', 'label' => 'Durchwahl', 'value' => '42' }])
      end

      mobile = card.fields.find { |one| one.label == 'Mobil' }
      expect(mobile.values.map { |value| [value.text, value.sources.size] }).to eq([['0171 5550100', 2]])
      expect(mobile.differs).to be(false)
      extension = card.fields.find { |one| one.label == 'Durchwahl' }
      expect(extension.values.map { |value| [value.text, value.sources.size] }).to eq([['42', 1]])
      expect(extension.differs).to be(true)
      # The fixed fields first, then the details in the order they first appear.
      expect(card.fields.map(&:label).compact).to eq(%w[Mobil Kundennummer Durchwahl])
    end

    it 'keeps two values one source has under the same label' do
      ActsAsTenant.with_tenant(north) do
        north_kai.update!(additional_details: [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '0171 1' },
                                               { 'kind' => 'phone', 'label' => 'Mobil', 'value' => '0172 2' }])
      end
      ActsAsTenant.with_tenant(south) do
        south_kai.update!(additional_details: [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '0172 2' }])
      end

      mobile = card.fields.find { |one| one.label == 'Mobil' }
      expect(mobile.values.map { |value| [value.text, value.sources.size] }).to eq([['0171 1', 1], ['0172 2', 2]])
      expect(mobile.differs).to be(true)
    end

    it 'treats equal sets of additional values as agreement regardless of order or repeated values' do
      details = [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '0171 1' },
                 { 'kind' => 'phone', 'label' => 'Mobil', 'value' => '0172 2' }]
      ActsAsTenant.with_tenant(north) { north_kai.update!(additional_details: details) }
      ActsAsTenant.with_tenant(south) do
        south_kai.update!(additional_details: [details.last, details.first.merge('value' => '01711'), details.first])
      end

      mobile = card.fields.find { |one| one.label == 'Mobil' }

      expect(mobile.values.map { |value| [value.text, value.sources.size] }).to eq([['0171 1', 2], ['0172 2', 2]])
      expect(mobile.differs).to be(false)
    end

    # The people page names a detail without a label by the name of its kind, in the
    # reader's language; the card did by the stored word ("phone"), and kept it apart from
    # the same detail another organisation labelled "Telefon".
    it 'names a detail without a label as the people page does, and joins it with the same label elsewhere' do
      ActsAsTenant.with_tenant(north) do
        north_kai.update!(additional_details: [{ 'kind' => 'phone', 'label' => '', 'value' => '+49 30 5550199' }])
      end
      ActsAsTenant.with_tenant(south) do
        south_kai.update!(additional_details: [{ 'kind' => 'phone', 'label' => 'Telefon', 'value' => '+49 30 5550199' }])
      end

      german = I18n.with_locale(:de) { card_at(address_of(north, person: north_kai)) }
      expect(german.fields.filter_map(&:label)).to eq(['Telefon'])
      expect(values(german, 'detail:telefon')).to eq([['+49 30 5550199', ['Nord GmbH', 'Sued AG']]])
      english = I18n.with_locale(:en) { card_at(address_of(north, person: north_kai)) }
      expect(english.fields.filter_map(&:label)).to eq(%w[Phone Telefon])
      # The stored word is the kind of a value (Value#kind), never what the card writes.
      expect(german.fields.flat_map { |one| [one.label, *one.values.map(&:text)] }).not_to include('phone')
    end

    it 'carries the notes per source, as People::Lookup.card hands them out with notes: true and not otherwise' do
      allow(People::Lookup).to receive(:card).and_call_original

      expect(card.sources.map { |one| [one.organisation_name, one.notes] })
        .to eq([['Nord GmbH', 'Nur dienstags im Haus.'], ['Sued AG', 'Zahlt immer puenktlich.']])
      expect(People::Lookup).to have_received(:card).with(anything, notes: true, kind_names: true).twice
      # No field is made of them.
      expect(leaves(card.fields)).not_to include('Nur dienstags im Haus.')
    end

    it 'reads no notes when the lookup hands none out' do
      allow(People::Lookup).to(receive(:card).and_wrap_original { |original, entry, **| original.call(entry) })

      expect(card.sources.map(&:notes)).to eq([nil, nil])
      expect(leaves(card)).not_to include('Nur dienstags im Haus.')
    end

    it 'shows the newest last contact of all sources, with its organisation' do
      Prosopite.pause do
        meeting_in(north, at: Time.zone.local(2026, 3, 1, 10), person: north_kai)
        meeting_in(south, at: Time.zone.local(2026, 9, 5, 10), person: south_kai)
      end

      expect(card.last_contact).to eq(on: '2026-09-05', kind: 'meeting', organisation_id: south.id, organisation_name: 'Sued AG')
    end

    it 'has no last contact without one' do
      expect(card.last_contact).to be_nil
    end

    it 'hands out plain values and no Person' do
      values = leaves(card)

      expect(values.grep(Person)).to be_empty
      expect(values.grep(ApplicationRecord)).to be_empty
      expect(values).to include('Kai Kontakt', '+49 30 5550100', 'Nur dienstags im Haus.')
    end

    it 'gives every source its place on the people page of its organisation and the address of its form' do
      expect(source(card, north).lane).to eq(person_id: north_kai.id)
      expect(source(card, north).edit).to eq(person_id: north_kai.id)
      expect(source(card, south).edit).to eq(person_id: south_kai.id)
      expect(source(card, north).address).to eq("person:#{north_kai.id}")
    end

    # A value a source lacks is entered through the form of that source (Source#edit, the
    # pencil of "Was steht wo"), not through a value of the field.
    it 'gives every value the address of the form of each of its sources, and a source that lacks one its own' do
      phone = field(card, :phone)

      expect(phone.values.map { |value| value.sources.map(&:edit) }).to eq([[{ person_id: north_kai.id }]])
      expect(source(card, south).edit).to eq(person_id: south_kai.id)
      expect(card.holdings.find { |holding| holding.organisation_ids == [south.id] }.keys).not_to include(:phone)
      expect(field(card, :name).values.first.sources.map(&:edit)).to eq([{ person_id: north_kai.id }, { person_id: south_kai.id }])
    end

    context 'when the viewer may only read in one organisation' do
      before do
        Prosopite.pause do
          take_people_right(viewer, south)
          ActsAsTenant.with_tenant(south) do
            role = Membership.find_by!(user: viewer, organisation: south).role
            create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
          end
        end
      end

      it 'keeps the source, says that it cannot be edited and gives it no address of a form' do
        expect(card.sources.map(&:organisation_name)).to eq(['Nord GmbH', 'Sued AG'])
        expect(source(card, south).edit).to be_nil
        expect(source(card, north).edit).to eq(person_id: north_kai.id)
        function = field(card, :function)
        expect(function.values.map { |value| value.sources.map(&:edit) }).to eq([[{ person_id: north_kai.id }], [nil]])
        expect(field(card, :phone).values.map { |value| value.sources.map(&:edit) }).to eq([[{ person_id: north_kai.id }]])
      end
    end

    describe 'a reference is not a right' do
      def expect_north_alone(card)
        expect(card.sources.map(&:organisation_name)).to eq(['Nord GmbH'])
        expect(values(card, :function)).to eq([['Einkauf', ['Nord GmbH']]])
        expect(field(card, :phone).differs).to be(false)
        expect(leaves(card)).not_to include('Vertrieb', 'Zahlt immer puenktlich.', 'Sued AG', south.id)
        expect(card.merge_id).to be_nil
      end

      it 'leaves out a source of an organisation where the people right was taken away' do
        Prosopite.pause { take_people_right(viewer, south) }

        expect_north_alone(card)
      end

      it 'leaves out a source of an organisation where the membership is deactivated' do
        Prosopite.pause { ActsAsTenant.with_tenant(south) { Membership.find_by!(user: viewer, organisation: south).update!(active: false) } }

        expect_north_alone(card)
      end

      it 'answers the address of that source like an address that names nothing' do
        Prosopite.pause { take_people_right(viewer, south) }

        expect(card_at(address_of(south, person: south_kai))).to be_nil
      end
    end

    describe 'the takeover' do
      it 'is offered for a contact whose row has no account, as long as there is somewhere to take it' do
        expect(source(card, north).takeover).to eq(north_kai.id)
        expect(source(card, south).takeover).to eq(south_kai.id)
      end

      it 'is not offered without an organisation the viewer may create people in' do
        Prosopite.pause do
          take_people_right(viewer, south)
          ActsAsTenant.with_tenant(south) do
            role = Membership.find_by!(user: viewer, organisation: south).role
            create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
          end
        end

        # From the north there is nowhere to go (the south only reads); from the south there is.
        expect(source(card, north).takeover).to be_nil
        expect(source(card, south).takeover).to eq(south_kai.id)
      end

      it 'is not offered for the row of a deactivated member' do
        former = create(:user, first_name: 'Frieda', last_name: 'Frueher')
        Prosopite.pause do
          join_organisation(former, north, active: false)
          ActsAsTenant.with_tenant(north) { north_kai.update_columns(user_id: former.id) }
        end

        expect(source(card, north).takeover).to be_nil
      end
    end

    describe 'taking one source out' do
      it 'is not offered with two sources: that is dissolving the merge' do
        expect(card.sources.map(&:detachable)).to eq([false, false])
      end

      it 'is offered for every source of three' do
        west_kai = nil
        Prosopite.pause do
          join_organisation(viewer, west, admin: true)
          west_kai = person_in(west, name: 'Kai Kontakt', email: nil)
          create(:person_group_entry, person_group: merge, organisation: west, person_id: west_kai.id)
        end

        expect(card.sources.map(&:organisation_name)).to eq(['Nord GmbH', 'Sued AG', 'West KG'])
        expect(card.sources.map(&:detachable)).to eq([true, true, true])
      end
    end
  end

  # D12: "Was steht wo" in Herkunft. Per group of sources that hold the same fields: which
  # fields, in the order of the card, besides the name that every source has, and whether
  # they have notes. The lead's group first, then more before fewer, then the list order.
  describe 'what each source holds' do
    let!(:merge) { merge_of(viewer, [north, { person_id: north_kai.id }], [south, { person_id: south_kai.id }]) }
    let(:card) { card_at(address_of(north, person: north_kai)) }

    def holdings(card)
      names = card.sources.to_h { |source| [source.organisation_id, source.organisation_name] }
      card.holdings.map { |holding| [holding.organisation_ids.map { |id| names.fetch(id) }, holding.keys, holding.notes] }
    end

    def add_west(**attributes)
      Prosopite.pause do
        join_organisation(viewer, west, admin: true)
        person_in(west, name: 'Kai Kontakt', **attributes).tap do |west_kai|
          create(:person_group_entry, person_group: merge, organisation: west, person_id: west_kai.id)
        end
      end
    end

    it 'names the fields every source holds besides the name, in the order of the card, and its notes' do
      expect(holdings(card)).to eq([[['Nord GmbH'], %i[salutation function company email phone], true],
                                    [['Sued AG'], %i[salutation function company email], true]])
    end

    it 'groups the sources that hold the same fields, whatever their values' do
      add_west(salutation: 'Frau', function: 'Lager', company: 'Westwind KG', email: 'kai.west@example.com', notes: 'Ruft zurueck.')

      expect(holdings(card)).to eq([[['Nord GmbH'], %i[salutation function company email phone], true],
                                    [['Sued AG', 'West KG'], %i[salutation function company email], true]])
    end

    it 'keeps two sources apart when only one of them has notes' do
      add_west(salutation: 'Frau', function: 'Lager', company: 'Westwind KG', email: 'kai.west@example.com')

      expect(holdings(card).map(&:first)).to eq([['Nord GmbH'], ['Sued AG'], ['West KG']])
      expect(holdings(card).last).to eq([['West KG'], %i[salutation function company email], false])
    end

    it 'holds no field for a source with nothing but the name' do
      add_west(function: nil, company: nil, email: nil)

      expect(holdings(card).last).to eq([['West KG'], [], false])
    end

    # The lead (here the west, by the newer last contact on equal counts) comes first even
    # where another source holds more; after it more before fewer, then the list order.
    it 'puts the lead first, then the groups with more before those with fewer, then the order of the list' do
      west_kai = add_west(salutation: 'Frau', function: 'Lager', company: 'Westwind KG', email: 'kai.west@example.com',
                          department: 'Technik')
      Prosopite.pause do
        meeting_in(north, at: 9.days.ago, person: north_kai)
        meeting_in(west, at: 2.days.ago, person: west_kai)
      end

      expect(card.lead).to eq(west.id)
      expect(holdings(card)).to eq([[['West KG'], %i[salutation function department company email], false],
                                    [['Nord GmbH'], %i[salutation function company email phone], true],
                                    [['Sued AG'], %i[salutation function company email], true]])
    end

    it 'orders equal groups by the list, with the lead first inside its own group' do
      ActsAsTenant.with_tenant(north) { north_kai.update_columns(phone: nil) }
      west_kai = add_west(salutation: 'Frau', function: 'Lager', company: 'Westwind KG', email: 'kai.west@example.com',
                          notes: 'Ruft zurueck.')
      Prosopite.pause { meeting_in(west, at: 2.days.ago, person: west_kai) }

      expect(card.lead).to eq(west.id)
      expect(holdings(card)).to eq([[['West KG', 'Nord GmbH', 'Sued AG'], %i[salutation function company email], true]])
    end
  end

  describe 'a member of two organisations' do
    before do
      Prosopite.pause do
        join_organisation(shared, south)
        join_organisation(shared, north)
      end
    end

    let!(:north_row) do
      person_in(north, user: shared, name: 'Mara Mitglied', function: 'Lager', email: 'mara.lager@example.com',
                       phone: '+49 30 5550111')
    end
    let(:card) { card_at(address_of(north, person: north_row)) }

    it 'is one person without a merge: the account joins the sources' do
      expect(card.sources.map { |one| [one.organisation_name, one.kind] }).to eq([['Nord GmbH', 'member'], ['Sued AG', 'member']])
      expect(card.merge_id).to be_nil
      expect(card.avatar_user).to eq(shared)
      expect(card.sources.map(&:detachable)).to eq([false, false])
    end

    it 'shows the email the member shows to others, never the one of the row' do
      expect(values(card, :email)).to eq([['mara@example.com', ['Nord GmbH', 'Sued AG']]])
      expect(leaves(card)).not_to include('mara.lager@example.com')
    end

    it 'shows no email when the member shows none' do
      shared.update!(email_visibility: 'none')

      expect(field(card, :email)).to be_nil
      expect(leaves(card)).not_to include('mara@example.com', 'mara.lager@example.com')
    end

    it 'gives the name and the email of a member no address of a form: they belong to the account' do
      expect(field(card, :name).values.flat_map { |value| value.sources.map(&:edit) }).to eq([nil, nil])
      expect(field(card, :email).values.flat_map { |value| value.sources.map(&:edit) }).to eq([nil, nil])
      expect(field(card, :function).values.first.sources.map(&:edit)).to eq([{ person_id: north_row.id }])
    end

    it 'gives a member without a row the address of the form that adds the details' do
      expect(source(card, south).lane).to eq(member_id: shared.id)
      expect(source(card, south).edit).to eq(member_id: shared.id)
      expect(source(card, south).address).to eq("member:#{shared.id}")
      # What the south lacks is edited there, through that form (the pencil of its source).
      expect(field(card, :phone).values.map { |value| value.sources.map(&:organisation_id) }).to eq([[north.id]])
      expect(card.holdings.map { |holding| [holding.organisation_ids, holding.keys] })
        .to eq([[[north.id], %i[function company email phone]], [[south.id], %i[email]]])
      expect(source(card, south).takeover).to be_nil
      expect(source(card, north).takeover).to be_nil
    end

    it 'opens from the member without a row as well' do
      expect(card_at(address_of(south, member: shared))).to eq(card)
    end

    # The form that adds a member's details creates a row: without the right to create
    # people there the source is read only, like a row the viewer may not update.
    it 'gives a member without a row no address of a form where the viewer may only read' do
      Prosopite.pause do
        take_people_right(viewer, south)
        ActsAsTenant.with_tenant(south) do
          create(:permission, role: Membership.find_by!(user: viewer, organisation: south).role,
                              category: 'people', action: 'view_people', allowed: true)
          project = create(:project, organisation: south)
          [viewer, shared].each { |user| create(:project_permission, user: user, project: project, tickets_access: :read_only) }
        end
      end

      expect(card.sources.map(&:organisation_name)).to eq(['Nord GmbH', 'Sued AG'])
      expect(source(card, south).lane).to eq(member_id: shared.id)
      expect(source(card, south).edit).to be_nil
      expect(field(card, :phone).values.map { |value| value.sources.map(&:organisation_id) }).to eq([[north.id]])
      expect(card.holdings.map(&:organisation_ids)).to eq([[north.id], [south.id]])
      # The north still has its form.
      expect(source(card, north).edit).to eq(person_id: north_row.id)
    end

    # The account joins the north and the south; a merge adds contacts. Nothing stored
    # could take one of the account's two sources out, and with one contact there are
    # two parts: taking the contact out would be undoing the merge.
    describe 'merged with contacts' do
      let(:east) { create(:organisation, name: 'Ost eG') }
      let!(:west_contact) { person_in(west, name: 'M. Mitglied', email: nil) }
      let!(:group) do
        Prosopite.pause { join_organisation(viewer, west, admin: true) }
        merge_of(viewer, [north, { person_id: north_row.id }], [west, { person_id: west_contact.id }])
      end

      it 'offers to take out neither a source of the account nor the one contact' do
        expect(card.sources.map { |one| [one.organisation_name, one.kind] })
          .to eq([['Nord GmbH', 'member'], ['Sued AG', 'member'], ['West KG', 'contact']])
        expect(card.merge_id).to eq(group.id)
        expect(card.sources.map(&:detachable)).to eq([false, false, false])
      end

      it 'offers to take out each of two contacts, and still no source of the account' do
        Prosopite.pause do
          join_organisation(viewer, east, admin: true)
          east_contact = person_in(east, name: 'M. Mitglied', email: nil)
          create(:person_group_entry, person_group: group, organisation: east, person_id: east_contact.id)
        end

        expect(card.sources.map { |one| [one.organisation_name, one.detachable] })
          .to eq([['Nord GmbH', false], ['Ost eG', true], ['Sued AG', false], ['West KG', true]])
      end
    end

    # A member is on the members page as well, which asks another right. Seeing them
    # there is no right to their entry in the people directory: without the people right
    # the organisation contributes nothing to the card, a member's source included.
    it 'leaves out the source of an organisation without the people right, also for a member the viewer still sees there' do
      Prosopite.pause do
        take_people_right(viewer, south)
        ActsAsTenant.with_tenant(south) do
          project = create(:project, organisation: south)
          [viewer, shared].each { |user| create(:project_permission, user: user, project: project, tickets_access: :read_only) }
        end
      end
      seen_as_member = ActsAsTenant.with_tenant(south) do
        MembershipPolicy::Scope.new(User.find(viewer.id), Membership).resolve.exists?(user_id: shared.id, organisation_id: south.id)
      end
      expect(seen_as_member).to be(true)

      expect(card.sources.map(&:organisation_name)).to eq(['Nord GmbH'])
      expect(leaves(card)).not_to include('Sued AG', south.id)
      expect(field(card, :function).differs).to be(false)
      expect(card_at(address_of(south, member: shared))).to be_nil
    end
  end

  describe 'a person of one organisation' do
    let(:card) { card_at(address_of(north, person: north_kai)) }

    it 'has one source, its lead, and no field that differs' do
      expect(card.sources.map(&:organisation_name)).to eq(['Nord GmbH'])
      expect(card.lead).to eq(north.id)
      expect(card.fields.map(&:differs)).to all(be(false))
      expect(card.merge_id).to be_nil
      expect(values(card, :phone)).to eq([['+49 30 5550100', ['Nord GmbH']]])
    end
  end

  describe 'an address that names nothing' do
    it 'answers nil for an unknown, a foreign, an invisible and a malformed address alike' do
      Prosopite.pause { join_organisation(create(:user), west, admin: true) }
      foreign = person_in(west, name: 'Wanda West')
      account = User.find(viewer.id)

      expect(card_at(address_of(north, person: north_kai))).not_to be_nil
      ["#{north.id}:person:#{SecureRandom.uuid}",
       address_of(west, person: foreign),
       "#{north.id}:person:#{foreign.id}",
       "#{south.id}:person:#{north_kai.id}",
       "#{north.id}:member:#{viewer.id}x",
       "#{north.id}:new",
       "#{north.id}:", ":person:#{north_kai.id}", "person:#{north_kai.id}", 'oops', '', nil, [north.id], { id: north.id }].each do |address|
        # The same question fourteen times is the spec's doing, not a read per row.
        expect(Prosopite.pause { described_class.call(viewer: account, address: address) }).to be_nil, "expected no card for #{address.inspect}"
      end
    end

    it 'answers nil for a row linked to a member the viewer cannot see' do
      stranger = create(:user, first_name: 'Sven', last_name: 'Fremd')
      hidden = nil
      Prosopite.pause do
        take_people_right(viewer, north)
        ActsAsTenant.with_tenant(north) do
          role = Membership.find_by!(user: viewer, organisation: north).role
          create(:permission, role: role, category: 'people', action: 'manage_people', allowed: true)
          create(:project_permission, user: viewer, project: create(:project, organisation: north), tickets_access: :read_only)
        end
        join_organisation(stranger, north)
        ActsAsTenant.with_tenant(north) do
          create(:project_permission, user: stranger, project: create(:project, organisation: north), tickets_access: :read_only)
        end
        hidden = person_in(north, user: stranger, name: 'Sven Fremd', phone: 'secret')
      end

      expect(card_at(address_of(north, person: north_kai))).not_to be_nil
      expect(card_at(address_of(north, person: hidden))).to be_nil
      expect(card_at(address_of(north, member: stranger))).to be_nil
    end
  end

  describe 'the tenant' do
    # People is tenanted (require_tenant): a read outside a tenant raises, and lifting the
    # tenant is what the card must not need.
    let(:lift) { %w[without tenant].join('_').to_sym }

    before { merge_of(viewer, [north, { person_id: north_kai.id }], [south, { person_id: south_kai.id }]) }

    it 'reads people and memberships only under the tenant of an organisation the viewer is an active member of' do
      Prosopite.pause do
        join_organisation(viewer, west, admin: true, active: false)
        person_in(west, name: 'Willi West')
      end
      tenants = []
      counter = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        tenants << ActsAsTenant.current_tenant if payload[:sql].match?(/FROM "(people|memberships)"/)
      end
      allow(ActsAsTenant).to receive(lift).and_call_original
      expect(ActsAsTenant.current_tenant).to be_nil

      card = card_at(address_of(south, person: south_kai))

      expect(card.sources.size).to eq(2)
      expect(tenants).not_to be_empty
      expect(tenants.uniq).to contain_exactly(north, south)
      expect(ActsAsTenant).not_to have_received(lift)
      expect(ActsAsTenant.current_tenant).to be_nil
    ensure
      ActiveSupport::Notifications.unsubscribe(counter)
    end

    it 'asks the right to write under the tenant of the source, not under the one of the request' do
      asked = []
      allow(PersonPolicy).to receive(:new).and_wrap_original do |original, *arguments|
        asked << ActsAsTenant.current_tenant
        original.call(*arguments)
      end

      ActsAsTenant.with_tenant(south) { card_at(address_of(north, person: north_kai)) }

      expect(asked).to include(north, south)
      expect(asked - [north, south]).to be_empty
    end

    it 'leaves no tenant behind when a source cannot be read' do
      allow(People::Lookup).to receive(:card).and_raise(ActiveRecord::StatementInvalid, 'gone')

      expect { card_at(address_of(north, person: north_kai)) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(ActsAsTenant.current_tenant).to be_nil
    end
  end

  describe 'one read for the page and its card' do
    it 'takes the read of the list and builds no second directory' do
      merge_of(viewer, [north, { person_id: north_kai.id }], [south, { person_id: south_kai.id }])
      account = User.find(viewer.id)
      across = People::AcrossOrganisations.new(viewer: account, query: 'kai')
      allow(People::Directory).to receive(:new).and_call_original

      list = across.call
      card = described_class.call(viewer: account, address: address_of(north, person: north_kai), across: across)

      expect(list.rows.map(&:name)).to eq(['Kai Kontakt'])
      expect(card.sources.size).to eq(2)
      expect(People::Directory).to have_received(:new).twice
    end
  end
end
