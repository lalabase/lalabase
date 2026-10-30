# frozen_string_literal: true

require 'rails_helper'

RSpec.describe People::Directory, :ci_guard do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*actions, title: nil)
    role = create(:role, organisation: organisation, **{ title: title }.compact)
    actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
    role
  end

  def member(first, last, role: role_with, active: true)
    user = create(:user, first_name: first, last_name: last)
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    User.find(user.id)
  end

  let(:project) { create(:project, organisation: organisation) }
  let(:other_project) { create(:project, organisation: organisation) }
  let(:viewer) { member('Vera', 'Viewer', role: role_with('view_people')) }
  let(:admin) { member('Anna', 'Admin', role: role_with(title: Role::ACCOUNT_ADMIN_TITLE)) }
  let(:colleague) { member('Carl', 'Kollege') }
  let(:stranger) { member('Sven', 'Fremd') }
  let!(:contact) { create(:person, organisation: organisation, name: 'Doris Dienstleister', company: 'Hosting AG') }

  before do
    create(:project_permission, user: viewer, project: project, tickets_access: :read_only)
    create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
    create(:project_permission, user: stranger, project: other_project, tickets_access: :read_only)
  end

  def entries(user = viewer, **options)
    described_class.new(viewer: user, organisation: organisation, **options).entries
  end

  def names(list)
    list.map { |entry| entry.person&.name || entry.user.display_name }
  end

  it 'lists the visible members and the contacts, sorted by name' do
    expect(names(entries)).to eq(['Carl Kollege', 'Doris Dienstleister', 'Vera Viewer'])
  end

  it 'follows MembershipPolicy::Scope: a member of a foreign project is absent for a non-admin' do
    create(:person, organisation: organisation, user: stranger, name: 'Sven Fremd', phone: '1')

    expect(names(entries)).not_to include('Sven Fremd')
    expect(names(entries(admin))).to include('Sven Fremd')
  end

  it 'attaches the person row of a member' do
    row = create(:person, organisation: organisation, user: colleague, name: 'Carl Kollege', function: 'Admin')

    entry = entries.find { |item| item.user == colleague }
    expect(entry).to be_member
    expect(entry.person).to eq(row)
  end

  it 'shows a row linked to a deactivated member as a contact' do
    row = create(:person, organisation: organisation, user: colleague, name: 'Carl Kollege')
    Membership.find_by(user: colleague, organisation: organisation).update!(active: false)

    list = entries
    expect(list.find { |item| item.person == row }.kind).to eq(:contact)
    expect(list.count { |item| item.user == colleague }).to eq(0)
  end

  # Review of S1 (28.10.2026): a contact row keeps the name it was saved with.
  # Search and order read that name, never the account's current one, so the
  # search cannot tell which account a former member's row belonged to.
  it 'searches and sorts the row of a deactivated member by the row name, not the account name' do
    row = create(:person, organisation: organisation, user: colleague, name: 'Carl Kollege')
    Membership.find_by(user: colleague, organisation: organisation).update!(active: false)
    colleague.update!(first_name: 'Zacharias', last_name: 'Umbenannt')

    expect(names(entries(query: 'zacharias'))).to eq([])
    expect(entries(query: 'kollege').map(&:person)).to eq([row])
    expect(names(entries)).to eq(['Carl Kollege', 'Doris Dienstleister', 'Vera Viewer'])
  end

  # The email of a member is the account's; a row email left on a member row is
  # not shown, so it must not be searchable either.
  it 'does not search the row email of a member row' do
    create(:person, organisation: organisation, user: colleague, email: 'versteckt@example.com')

    expect(names(entries(query: 'versteckt'))).to eq([])
  end

  # The member chooses which email the others see (User::EmailDisplay). A search
  # must not confirm a hidden login address.
  it 'searches the email a member shows, never a hidden login address' do
    colleague.update!(email_visibility: 'contact', contact_email: 'carl.team@example.com')

    expect(names(entries(query: 'carl.team'))).to eq(['Carl Kollege'])
    expect(names(entries(query: colleague.email))).to eq([])
  end

  it 'finds no email of a member who shows none' do
    colleague.update!(email_visibility: 'none')

    expect(names(entries(query: colleague.email))).to eq([])
  end

  # One directory per example: each call resolves the viewer's reach once, and
  # Prosopite would read a second call as an N+1.
  {
    'members' => ['Carl Kollege', 'Vera Viewer'],
    'contacts' => ['Doris Dienstleister'],
    'nonsense' => ['Carl Kollege', 'Doris Dienstleister', 'Vera Viewer']
  }.each do |kind, expected|
    it "filters by kind #{kind}" do
      expect(names(entries(kind: kind))).to eq(expected)
    end
  end

  {
    'hosting' => ['Doris Dienstleister'],
    'mueller' => ['Jürgen Müller'],
    'Müller' => ['Jürgen Müller'],
    'kollege' => ['Carl Kollege'],
    'zzz' => []
  }.each do |query, expected|
    it "searches the fields umlaut-insensitive (#{query})" do
      create(:person, organisation: organisation, name: 'Jürgen Müller', company: nil)

      expect(names(entries(query: query))).to eq(expected)
    end
  end

  # Often only "Frau Müller" is known: the name is "Müller", the salutation
  # "Frau". A search for what one would say finds her, and only her.
  it 'finds a person by salutation and name together' do
    frau = create(:person, organisation: organisation, name: 'Müller', salutation: 'Frau', company: nil)
    create(:person, organisation: organisation, name: 'Müller', salutation: 'Herr', company: nil)

    found = described_class.new(viewer: admin, organisation: organisation, query: 'Frau Müller')

    expect(found.entries.map(&:person)).to eq([frau])
    expect(found.candidates.map(&:person)).to eq([frau])
  end

  # D3: the values of the additional details are searched, never their labels
  # ("Fax" would find everybody with a fax).
  describe 'the additional details' do
    let!(:with_details) do
      create(:person, organisation: organisation, name: 'Gerd Gast', company: nil,
                      additional_details: [{ 'kind' => 'phone', 'label' => 'Fax', 'value' => '+49 30 9876543' },
                                           { 'kind' => 'address', 'label' => 'Büro', 'value' => "Hauptstraße 5\n12345 Köln" }])
    end

    def found(query)
      described_class.new(viewer: admin, organisation: organisation, query: query)
    end

    it 'finds a person by a value, also umlaut-normalized' do
      expect(found('9876543').entries.map(&:person)).to eq([with_details])
      expect(found('hauptstrasse').entries.map(&:person)).to eq([with_details])
      expect(found('Koeln').candidates.map(&:person)).to eq([with_details])
    end

    it 'does not find a person by a label alone' do
      expect(found('Fax').entries).to be_empty
      expect(found('Büro').entries).to be_empty
      expect(found('Gast').entries.map(&:person)).to eq([with_details])
    end

    it 'finds the details of a member row' do
      create(:person, organisation: organisation, user: colleague, name: 'Carl Kollege',
                      additional_details: [{ 'kind' => 'url', 'label' => 'Web', 'value' => 'https://kollege.example.com' }])

      expect(found('kollege.example').entries.map(&:user)).to eq([colleague])
    end
  end

  # External review of 26.10.2026: a linked member is compared by the name
  # the directory shows, not by the copy taken when the row was linked.
  it 'finds duplicates of a member by the current account name' do
    row = create(:person, organisation: organisation, user: colleague, name: 'Carl Kollege')
    colleague.update!(first_name: 'Carlo', last_name: 'Neu')
    namesake = create(:person, organisation: organisation, name: 'Carlo Neu')
    old_namesake = create(:person, organisation: organisation, name: 'Carl Kollege')

    duplicates = described_class.new(viewer: admin, organisation: organisation).duplicates_of(row.reload)

    expect(duplicates.map(&:person)).to include(namesake)
    expect(duplicates.map(&:person)).not_to include(old_namesake)
  end

  # S2a: the last contact of each entry and the sort "Zuletzt" (E5).
  describe 'last contact and sort' do
    let(:hidden_project) { create(:project, organisation: organisation) }

    before do
      ProjectPermission.find_by(user: viewer, project: project).update!(meetings_access: :read_only)
    end

    def meeting(project_for, at:, person: nil, user: nil)
      record = create(:meeting, organisation: organisation, project: project_for, occurred_at: at)
      create(:meeting_participant, meeting: record, person: person, user: user, display_name: 'Gast')
    end

    it 'gives every entry its last readable contact' do
      meeting(project, at: 3.days.ago, person: contact)
      meeting(hidden_project, at: 1.day.ago, user: colleague)

      list = entries.index_by { |entry| entry.person&.name || entry.user.first_name }

      expect(list['Doris Dienstleister'].last_contact.kind).to eq(:meeting)
      expect(list['Carl'].last_contact).to be_nil
    end

    it 'keeps sorting by name unless asked' do
      meeting(project, at: 1.day.ago, user: viewer)

      expect(names(entries)).to eq(['Carl Kollege', 'Doris Dienstleister', 'Vera Viewer'])
      expect(names(entries(sort: 'nonsense'))).to eq(['Carl Kollege', 'Doris Dienstleister', 'Vera Viewer'])
    end

    it 'sorts by last contact, newest first, people without any contact last' do
      meeting(project, at: 5.days.ago, person: contact)
      meeting(project, at: 1.day.ago, user: viewer)

      expect(names(entries(sort: 'last'))).to eq(['Vera Viewer', 'Doris Dienstleister', 'Carl Kollege'])
    end

    it 'is not moved by a meeting the viewer may not read' do
      meeting(project, at: 5.days.ago, person: contact)
      meeting(hidden_project, at: 1.hour.ago, user: colleague)

      expect(names(entries(sort: 'last')).first).to eq('Doris Dienstleister')
      expect(names(entries(admin, sort: 'last')).first).to eq('Carl Kollege')
    end

    # People S3: the assistant's card (get_person) asks for ONE entry's last contact, the
    # way the list asks for all of them, under the same rights.
    it 'answers the last contact of the entries asked about, in their order, only what the viewer reads' do
      meeting(project, at: 3.days.ago, person: contact)
      meeting(hidden_project, at: 1.day.ago, user: colleague)
      directory = described_class.new(viewer: viewer, organisation: organisation)

      lasts = directory.last_contacts_for([directory.member_entry(colleague.id), directory.person_entry(contact.id)])

      expect(lasts.size).to eq(2)
      expect(lasts.first).to be_nil
      expect(lasts.last.kind).to eq(:meeting)
      expect(directory.last_contacts_for([])).to eq([])
    end
  end

  describe 'the link dialog (S2b)' do
    def directory(user = viewer, query: nil)
      described_class.new(viewer: user, organisation: organisation, query: query)
    end

    it 'finds a person row by id only when the viewer sees it, a member row as the member' do
      stranger_row = create(:person, organisation: organisation, user: stranger, name: 'Sven Fremd')
      colleague_row = create(:person, organisation: organisation, user: colleague, name: 'Carl Kollege')

      expect(directory.person_entry(contact.id).person).to eq(contact)
      expect(directory.person_entry(stranger_row.id)).to be_nil
      expect(directory(admin).person_entry(stranger_row.id)).to be_present
      expect(directory.person_entry(colleague_row.id)).to be_member
      expect(directory(colleague).person_entry(contact.id)).to be_nil
    end

    it 'lists candidates by search, without last contacts' do
      expect(names(directory(query: 'hosting').candidates)).to eq(['Doris Dienstleister'])
      expect(directory.candidates.map(&:last_contact)).to all(be_nil)
      expect(names(directory.candidates)).to eq(['Carl Kollege', 'Doris Dienstleister', 'Vera Viewer'])
    end

    it 'suggests the same full name first, then the same surname, only what the viewer sees' do
      same_surname = create(:person, organisation: organisation, name: 'Anton Dienstleister')
      same_name = create(:person, organisation: organisation, name: 'doris dienstleister')
      create(:person, organisation: organisation, user: stranger, name: 'Sven Dienstleister')

      suggested = directory.suggestions_for('Doris Dienstleister').map(&:person)

      expect(suggested.first(2)).to contain_exactly(contact, same_name)
      expect(suggested.last).to eq(same_surname)
      expect(suggested.size).to eq(3)
    end

    it 'reads the surname past initials and a note in brackets' do
      expect(described_class.surname('J. Weber (Hoster)')).to eq('weber')
      expect(described_class.surname('Jürgen Müller')).to eq('mueller')
      expect(described_class.surname('J.')).to be_nil
      expect(directory.suggestions_for(' ')).to eq([])
    end

    describe '#entry_for_participant' do
      let(:meeting) { create(:meeting, organisation: organisation, project: project) }

      def participant(name, **keys)
        create(:meeting_participant, meeting: meeting, display_name: name, **keys)
      end

      it 'is the member for a member participant' do
        expect(directory(admin).entry_for_participant(participant('Carl', user: colleague)).user).to eq(colleague)
      end

      it 'is the row that keeps their meetings for a deactivated member' do
        row = create(:person, organisation: organisation, name: 'Carl Kollege', user: colleague)
        Membership.where(user: colleague).update_all(active: false)

        entry = directory(admin).entry_for_participant(participant('Carl', user: colleague))

        expect(entry).not_to be_member
        expect(entry.person).to eq(row)
      end

      it 'is the row for a contact, and the member when that row is a member\'s' do
        member_row = create(:person, organisation: organisation, name: 'Carl Kollege', user: colleague)

        expect(directory(admin).entry_for_participant(participant('Doris', person: contact)).person).to eq(contact)
        expect(directory(admin).entry_for_participant(participant('Carl', person: member_row))).to be_member
      end

      it 'is nil for a free name, and for someone the viewer may not see' do
        expect(directory(admin).entry_for_participant(participant('Frei'))).to be_nil
        expect(directory.entry_for_participant(participant('Sven', user: stranger))).to be_nil
      end
    end

    describe '#former_member_entry' do
      it 'is the contact entry of a deactivated member, nil while they are active' do
        row = create(:person, organisation: organisation, name: 'Carl Kollege', user: colleague)

        expect(directory(admin).former_member_entry(colleague.id)).to be_nil
        Membership.where(user: colleague).update_all(active: false)
        expect(directory(admin).former_member_entry(colleague.id).person).to eq(row)
      end
    end

    describe 'Entry#detail' do
      def entry(**fields)
        described_class::Entry.new(**fields)
      end

      it 'is function and company of a row, joined' do
        person = build(:person, function: 'CTO', company: 'Beispiel GmbH')

        expect(entry(kind: :contact, person: person).detail).to eq('CTO · Beispiel GmbH')
        expect(entry(kind: :contact, person: build(:person, function: nil, company: 'Beispiel GmbH')).detail)
          .to eq('Beispiel GmbH')
      end

      it "is a member's email without function and company, and nothing for such a contact" do
        user = build(:user, email: 'carl@example.com')

        bare = { function: nil, company: nil }

        expect(entry(kind: :member, user: user, person: build(:person, **bare)).detail).to eq('carl@example.com')
        expect(entry(kind: :member, user: user).detail).to eq('carl@example.com')
        expect(entry(kind: :contact, person: build(:person, email: 'doris@example.com', **bare)).detail).to be_nil
      end

      it 'is the email a member shows to others, and falls through when they show none' do
        bare = { function: nil, company: nil }
        contact = build(:user, email: 'carl@example.com', email_visibility: 'contact', contact_email: 'carl.team@example.com')
        hidden = build(:user, email: 'carl@example.com', email_visibility: 'none')

        expect(entry(kind: :member, user: contact).detail).to eq('carl.team@example.com')
        expect(entry(kind: :member, user: hidden).detail).to be_nil
        expect(entry(kind: :member, user: hidden, person: build(:person, salutation: 'Herr', **bare)).detail).to eq('Herr')
      end

      # Two contacts named "Müller" without function or company: the salutation
      # tells them apart in the list and in the link dialog.
      it 'is the salutation of a row without function and company' do
        bare = { function: nil, company: nil }

        expect(entry(kind: :contact, person: build(:person, salutation: 'Frau', **bare)).detail).to eq('Frau')
        expect(entry(kind: :contact, person: build(:person, salutation: 'Frau', function: 'CTO', company: nil)).detail)
          .to eq('CTO')
        expect(entry(kind: :member, user: build(:user, email: 'carl@example.com'),
                     person: build(:person, salutation: 'Herr', **bare)).detail).to eq('carl@example.com')
      end
    end
  end

  it 'returns nothing without the right' do
    expect(entries(colleague)).to be_empty
  end
end
