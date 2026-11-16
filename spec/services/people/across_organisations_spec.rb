# frozen_string_literal: true

require 'rails_helper'

# What: People::AcrossOrganisations, the read of the people list above the organisations
#   (GET /people): the people of every organisation the viewer is an active member of and
#   holds the people right in, as one list.
# Type: Service spec against real rows in two organisations (and a third the viewer left).
# Why:  the list crosses tenants, so everything it must not do is pinned here: read with the
#   tenant lifted, read an organisation without the right or name it, merge two people who
#   only share a name, hand out a record a view could load more from, or read an
#   organisation more than once per request.
RSpec.describe People::AcrossOrganisations, :ci_guard do
  include AllPeopleHelpers

  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Sued AG') }
  let(:west) { create(:organisation, name: 'West KG') }
  let(:viewer) { create(:user, first_name: 'Vera', last_name: 'Viewer', email: 'vera@example.com') }
  let(:shared) { create(:user, first_name: 'Mara', last_name: 'Mitglied', email: 'mara@example.com') }

  # A fresh account object per read, as a request has one: the rights caches of User are
  # per instance.
  def list(**options)
    described_class.call(viewer: User.find(viewer.id), **options)
  end

  def names(result)
    result.rows.map(&:name)
  end

  def organisations_of(row)
    row.sources.map(&:organisation_name)
  end

  def row_named(result, name)
    result.rows.find { |row| row.name == name }
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

  # Before the rows below: a row of a member needs the membership. South comes first on
  # purpose: the organisation with the later name is the older one, so the order by name
  # (chips, the first source, the filter) is never the order of creation by accident.
  before do
    Prosopite.pause do
      join_organisation(viewer, south, admin: true)
      join_organisation(viewer, north, admin: true)
      join_organisation(shared, south)
      join_organisation(shared, north)
    end
  end

  let!(:north_row) do
    person_in(north, user: shared, name: 'Mara Mitglied', function: nil, company: nil, department: 'Lager',
                     email: 'mara.lager@example.com', phone: '+49 30 5550100', notes: 'Nur dienstags im Haus.')
  end
  let!(:north_contact) { person_in(north, name: 'Kai Kontakt', function: 'Einkauf', company: 'Nordlicht AG') }
  let!(:south_contact) { person_in(south, name: 'Kai Kontakt', function: 'Vertrieb', company: 'Suedwind AG') }
  let!(:north_only) do
    person_in(north, name: 'Nora Nord', function: 'Leitung IT', company: 'Hosting AG',
                     email: 'nora@example.com', phone: '+49 30 5550199', notes: 'Bitte nicht vor zehn anrufen.')
  end

  after { ActsAsTenant.current_tenant = nil }

  describe 'the list' do
    it 'holds the people of every organisation, sorted by name, each row with its organisations' do
      result = list

      expect(result.rows.map { |row| [row.name, organisations_of(row)] }).to eq(
        [['Kai Kontakt', ['Nord GmbH']], ['Kai Kontakt', ['Sued AG']], ['Mara Mitglied', ['Nord GmbH', 'Sued AG']],
         ['Nora Nord', ['Nord GmbH']], ['Vera Viewer', ['Nord GmbH', 'Sued AG']]]
      )
      expect(result.total).to eq(5)
      expect(result.organisations).to eq([{ id: north.id, name: 'Nord GmbH' }, { id: south.id, name: 'Sued AG' }])
    end

    it 'makes a member with the same account in two organisations one row with two sources' do
      row = row_named(list, 'Mara Mitglied')

      expect(row.kind).to eq('member')
      expect(row.sources.map { |source| [source.organisation_id, source.lane, source.fields[:id]] }).to eq(
        [[north.id, { person_id: north_row.id }, "member:#{shared.id}"],
         [south.id, { member_id: shared.id }, "member:#{shared.id}"]]
      )
      expect(row.avatar_user).to eq(shared)
    end

    # An empty field of a form is stored as an empty text, not as nothing: it is no value either.
    it 'takes function, department and company from the first source that has one' do
      ActsAsTenant.with_tenant(north) { north_row.update!(function: '') }
      person_in(south, user: shared, name: 'Mara Mitglied', function: 'Beraterin', company: nil, department: 'Vertrieb')

      row = row_named(list, 'Mara Mitglied')

      expect([row.function, row.department, row.company]).to eq(['Beraterin', 'Lager', nil])
    end

    it 'keeps two contacts of the same name in two organisations as two rows' do
      rows = list.rows.select { |row| row.name == 'Kai Kontakt' }

      expect(rows.map { |row| [row.kind, organisations_of(row), row.function] })
        .to eq([['contact', ['Nord GmbH'], 'Einkauf'], ['contact', ['Sued AG'], 'Vertrieb']])
      expect(rows.map { |row| row.sources.first.lane })
        .to eq([{ person_id: north_contact.id }, { person_id: south_contact.id }])
      expect(rows.map(&:avatar_user)).to eq([nil, nil])
    end

    it 'never merges a member with a contact of the same name' do
      person_in(south, name: 'Mara Mitglied', function: 'Empfang', company: nil)

      rows = list.rows.select { |row| row.name == 'Mara Mitglied' }

      expect(rows.map { |row| [row.kind, organisations_of(row)] })
        .to contain_exactly(['member', ['Nord GmbH', 'Sued AG']], ['contact', ['Sued AG']])
    end

    # A deactivated membership: the directory lists that member's row as a contact, and a
    # contact is alone, also when its account is a member elsewhere.
    it 'keeps the row of a former member apart from the member with the same account elsewhere' do
      south_row = person_in(south, user: shared, name: 'Mara Mitglied', function: 'Beraterin', company: nil)
      Membership.find_by!(user: shared, organisation: south).update!(active: false)

      rows = list.rows.select { |row| row.name == 'Mara Mitglied' }

      expect(rows.map { |row| [row.kind, organisations_of(row), row.sources.map(&:lane)] }).to contain_exactly(
        ['member', ['Nord GmbH'], [{ person_id: north_row.id }]],
        ['contact', ['Sued AG'], [{ person_id: south_row.id }]]
      )
    end

    it 'shows the newest last contact of the sources' do
      meeting_in(north, at: 5.days.ago, person: north_row)
      meeting_in(south, at: 2.days.ago, user: shared)

      row = row_named(list, 'Mara Mitglied')

      expect(row.last_contact).to eq(on: 2.days.ago.in_time_zone.to_date.iso8601, kind: 'meeting')
      expect(row_named(list, 'Nora Nord').last_contact).to be_nil
    end
  end

  describe 'the search' do
    it 'shows the whole person for a match on one entry: the source of the other organisation too' do
      result = list(query: 'lager')

      expect(names(result)).to eq(['Mara Mitglied'])
      expect(organisations_of(result.rows.first)).to eq(['Nord GmbH', 'Sued AG'])
      expect(result.total).to eq(1)
    end

    # The match may sit on any entry, not only on the one the row takes its name from.
    it 'shows the whole person for a match on the entry of the organisation that comes later by name' do
      person_in(south, user: shared, name: 'Mara Mitglied', function: 'Beraterin', company: nil)

      result = list(query: 'beraterin')

      expect(names(result)).to eq(['Mara Mitglied'])
      expect(organisations_of(result.rows.first)).to eq(['Nord GmbH', 'Sued AG'])
      expect(result.rows.first.function).to eq('Beraterin')
    end

    it 'searches every organisation with the search of its directory' do
      expect(list(query: 'kai').rows.map { |row| organisations_of(row) }).to eq([['Nord GmbH'], ['Sued AG']])
      expect(names(list(query: 'suedwind'))).to eq(['Kai Kontakt'])
      expect(names(list(query: '  NORA '))).to eq(['Nora Nord'])
    end

    it 'finds nothing by a note or by the address a member does not show' do
      expect(names(list(query: 'hosting'))).to eq(['Nora Nord'])
      expect(list(query: 'dienstags').rows).to be_empty
      expect(list(query: 'mara.lager').rows).to be_empty
    end

    it 'answers no match with no row, and still names the organisations' do
      result = list(query: 'niemand')

      expect([result.rows, result.total, result.page, result.pages]).to eq([[], 0, 1, 1])
      expect(result.organisations.pluck(:name)).to eq(['Nord GmbH', 'Sued AG'])
    end
  end

  describe 'a reference is not a right' do
    def expect_north_alone(result)
      expect(names(result)).to eq(['Kai Kontakt', 'Mara Mitglied', 'Nora Nord', 'Vera Viewer'])
      expect(result.rows.flat_map { |row| organisations_of(row) }.uniq).to eq(['Nord GmbH'])
      expect(result.organisations).to eq([{ id: north.id, name: 'Nord GmbH' }])
      expect(leaves(result).grep(String)).not_to include('Sued AG', south.id)
    end

    it 'shows nothing of an organisation where the viewer lacks the people right, and does not name it' do
      take_people_right(viewer, south)
      allow(People::Directory).to receive(:new).and_call_original

      expect_north_alone(list)
      expect(People::Directory).to have_received(:new).once.with(hash_including(organisation: north))
    end

    it 'shows nothing of an organisation where the membership is deactivated, and does not name it' do
      Membership.find_by!(user: viewer, organisation: south).update!(active: false)

      expect_north_alone(list)
    end

    it 'shows a member with view_people what the directory of that organisation shows them' do
      ActsAsTenant.with_tenant(south) do
        role = create(:role, organisation: south)
        create(:permission, role: role, category: 'people', action: 'view_people', allowed: true)
        Membership.find_by!(user: viewer, organisation: south).update!(role: role)
      end

      result = list

      expect(result.organisations.pluck(:name)).to eq(['Nord GmbH', 'Sued AG'])
      expect(result.rows.map { |row| [row.name, organisations_of(row)] })
        .to include(['Kai Kontakt', ['Sued AG']], ['Mara Mitglied', ['Nord GmbH']], ['Vera Viewer', ['Nord GmbH', 'Sued AG']])
    end
  end

  describe 'the organisation filter' do
    it 'narrows to the one organisation `org` names, sources included' do
      result = list(org: south.id)

      expect(result.rows.map { |row| [row.name, organisations_of(row)] })
        .to eq([['Kai Kontakt', ['Sued AG']], ['Mara Mitglied', ['Sued AG']], ['Vera Viewer', ['Sued AG']]])
      expect(result.organisations.pluck(:name)).to eq(['Nord GmbH', 'Sued AG'])
    end

    it 'reads only the organisation it narrows to' do
      allow(People::Directory).to receive(:new).and_call_original

      list(org: south.id.upcase).rows

      expect(People::Directory).to have_received(:new).twice
      expect(list(org: south.id.upcase).rows.flat_map { |row| organisations_of(row) }.uniq).to eq(['Sued AG'])
    end

    it 'reads an empty `org` as no filter' do
      expect(list(org: '').total).to eq(5)
      expect(list(org: nil).total).to eq(5)
    end

    it 'answers one refusal for every organisation the list cannot show' do
      foreign = create(:organisation, name: 'Fremd GmbH')
      Prosopite.pause do
        join_organisation(viewer, west, admin: true, active: false)
        join_organisation(viewer, create(:organisation, name: 'Ohne Recht AG'))
      end
      without_right = viewer.organisations.find_by!(name: 'Ohne Recht AG')

      # The loop repeats the read on purpose; the read itself is watched in the examples around.
      Prosopite.pause do
        [foreign.id, west.id, without_right.id, SecureRandom.uuid, 'oops', [north.id], { 'id' => north.id }, 7].each do |org|
          expect { list(org: org) }.to raise_error(described_class::UnknownOrganisation), org.inspect
        end
      end
      expect(ActsAsTenant.current_tenant).to be_nil
      expect(list(org: north.id).total).to eq(4)
    end
  end

  describe 'paging' do
    before do
      Prosopite.pause do
        (1..51).each { |number| person_in(north, name: format('Anton Beispiel %02d', number)) }
      end
    end

    it 'cuts the page at 50 rows, in the order of the names, and counts what was there before the cut' do
      first = list
      second = list(page: '2')

      expect([first.total, first.page, first.pages, first.per_page]).to eq([56, 1, 2, 50])
      expect(names(first)).to eq((1..50).map { |number| format('Anton Beispiel %02d', number) })
      expect(names(second)).to eq(['Anton Beispiel 51', 'Kai Kontakt', 'Kai Kontakt', 'Mara Mitglied', 'Nora Nord', 'Vera Viewer'])
      expect(second.page).to eq(2)
    end

    it 'holds a page that is no page of the list inside it' do
      pages = Prosopite.pause { ['0', 'abc', '-1', nil, ['2'], '1.5'].map { |page| list(page: page).page } }

      expect(pages).to all(eq(1))
      expect(list(page: '999').page).to eq(2)
      expect(list(page: '99999999999').page).to eq(2)
      expect(list(page: '9' * 40).page).to eq(2)
      expect(list(page: '0002').page).to eq(2)
      expect(list(page: 2).page).to eq(2)
    end

    # The page is cut after the merge, so the last contacts are a second pass: for the
    # entries of the page shown, never for the whole list.
    it 'asks for the last contacts of the rows of the shown page only' do
      asked = []
      allow(People::Lookup::Listing).to receive(:new).and_wrap_original do |original, **arguments|
        original.call(**arguments).tap do |listing|
          allow(listing).to receive(:last_contacts_for).and_wrap_original do |read, entries|
            asked.concat(entries.map(&:plain_name))
            read.call(entries)
          end
        end
      end

      second = list(page: 2)

      expect(asked).to match_array(['Anton Beispiel 51', 'Kai Kontakt', 'Kai Kontakt', 'Mara Mitglied', 'Mara Mitglied',
                                    'Nora Nord', 'Vera Viewer', 'Vera Viewer'])
      expect(names(second)).to include('Anton Beispiel 51')
    end
  end

  describe 'what leaves the read' do
    it 'hands out plain values and no Person: a view has nothing to load more from' do
      values = leaves(list)

      expect(values.grep(Person)).to be_empty
      expect(values.map(&:class).uniq - [String, NilClass, Integer, User]).to be_empty
      expect(values.grep(User)).to contain_exactly(shared, viewer)
      expect(values).to include('Nora Nord', north.id, north_only.id)
    end

    it 'gives a source the fields of a list row: no contact details and no notes' do
      result = list
      plain = leaves(result).grep(String)

      expect(result.rows.flat_map(&:sources).map { |source| source.fields.keys }.uniq)
        .to eq([%i[id name kind function department company last_contact]])
      expect(plain).to include('Leitung IT', 'Hosting AG', 'Lager')
      expect(plain.join("\n")).not_to match(/nora@example\.com|mara\.lager@example\.com|5550199|5550100|anrufen|dienstags/)
    end
  end

  describe 'the tenant' do
    # The rule this read exists for: no read with the tenant lifted. People is tenanted
    # (require_tenant), so a read outside a tenant would raise here, and lifting the tenant
    # is what the read must not need. West is an organisation the viewer left (a deactivated
    # membership): nothing is asked under it either.
    let(:lift) { %w[without tenant].join('_').to_sym }

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

      result = list(query: 'a')

      expect(names(result)).to include('Kai Kontakt', 'Mara Mitglied')
      expect(tenants).not_to be_empty
      expect(tenants.uniq).to contain_exactly(north, south)
      expect(ActsAsTenant).not_to have_received(lift)
      expect(ActsAsTenant.current_tenant).to be_nil
    ensure
      ActiveSupport::Notifications.unsubscribe(counter)
    end

    it 'leaves no tenant behind when the read is refused' do
      expect { list(org: 'oops') }.to raise_error(described_class::UnknownOrganisation)
      expect(ActsAsTenant.current_tenant).to be_nil
    end
  end

  describe 'one directory per organisation and request' do
    def statements
      found = []
      counter = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        found << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached]
      end
      yield
      found
    ensure
      ActiveSupport::Notifications.unsubscribe(counter)
    end

    # Contacts AND members, numbered before their kind and their organisation: sorted by
    # name, the first page then holds contacts and members of both organisations however
    # many there are, so the two runs ask for the same kinds of last contact and only the
    # number of rows differs. A read per contact row or per member row shows as a difference.
    def fill(organisation, count)
      Prosopite.pause do
        ActsAsTenant.with_tenant(organisation) do
          role = create(:role, organisation: organisation)
          count.times do |index|
            number = index.to_s.rjust(2, '0')
            create(:person, organisation: organisation, name: "Anton #{number} Beispiel #{organisation.name}")
            account = create(:user, first_name: 'Anton', last_name: "#{number} Mitglied #{organisation.name}")
            create(:membership, user: account, organisation: organisation, role: role)
          end
        end
      end
    end

    def members_on_page(result)
      result.rows.count { |row| row.kind == 'member' }
    end

    it 'builds one directory per organisation, also for a search and a later page' do
      allow(People::Directory).to receive(:new).and_call_original

      list(query: 'a', page: 2)

      expect(People::Directory).to have_received(:new).twice
      expect(People::Directory).to have_received(:new).with(hash_including(organisation: north)).once
      expect(People::Directory).to have_received(:new).with(hash_including(organisation: south)).once
    end

    it 'runs the member read and the contact read once per organisation' do
      sql = statements { list(query: 'a') }

      # The visible memberships of the organisation: the member half of its directory.
      member_reads = sql.grep(/\ASELECT "memberships"\.\* FROM "memberships" WHERE "memberships"\."organisation_id"/)
      # The rows of those members, and the contacts: one statement each.
      people_reads = sql.grep(/\ASELECT "people"\.\* FROM "people"/)
      expect(member_reads.size).to eq(2)
      expect(people_reads.size).to eq(4)
      expect(people_reads.count { |statement| statement.include?('"people"."user_id" IS NULL') }).to eq(2)
      expect(sql.grep(/FROM "people"/).size).to eq(4)
    end

    it 'asks the same number of statements for 5 and for 50 people per organisation' do
      [north, south].each { |organisation| fill(organisation, 3) }
      few = statements { list }
      [north, south].each { |organisation| fill(organisation, 45) }
      many = statements { list }

      expect(few.grep(/FROM "people"/).size).to eq(4)
      expect(many.grep(/FROM "people"/).size).to eq(4)
      expect(many.size).to eq(few.size)
      expect(list.total).to eq(197)
    end

    # The same count again, read as a rule about members: the first page of the long list
    # shows more members than the whole short list, for the same number of statements.
    it 'asks no statement per member on the page' do
      [north, south].each { |organisation| fill(organisation, 2) }
      few_members = members_on_page(list)
      few = statements { list }
      [north, south].each { |organisation| fill(organisation, 20) }
      many_members = members_on_page(list)
      many = statements { list }

      expect([few_members, many_members]).to eq([6, 24])
      expect(many.size).to eq(few.size)
    end
  end
end
