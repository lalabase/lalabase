# frozen_string_literal: true

require 'rails_helper'

# What: People::Lookup, the one read of the people directory behind the assistant's
#   find_people and get_person, their MCP twins and the REST people endpoints (People S3b).
# Type: Service spec against real rows.
# Why:  Three adapters read the directory through this object, so its rules are their rules:
#   the people right first (nothing read without it, a deactivated member included), the
#   page's own reach and search, a kind that is checked instead of read as "all", one id
#   format, the field lists (a row never carries contact details or notes, a card carries
#   notes only when asked) and the token rule E1 (only a token that reaches every project of
#   the organisation opens its directory).
RSpec.describe People::Lookup, :ci_guard do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*actions)
    role = create(:role, organisation: organisation)
    actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
    role
  end

  def member(first, last, role: role_with, active: true)
    user = create(:user, first_name: first, last_name: last, email: "#{first.downcase}@example.com")
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    User.find(user.id)
  end

  let(:project) { create(:project, organisation: organisation) }
  let(:hidden_project) { create(:project, organisation: organisation) }
  let(:viewer) { member('Vera', 'Viewer', role: role_with('view_people')) }
  let(:colleague) { member('Carl', 'Kollege') }
  let(:stranger) { member('Sven', 'Fremd') }
  let!(:contact) do
    create(:person, organisation: organisation, name: 'Doris Dienstleister', salutation: 'Frau',
                    function: 'Leitung IT', department: 'Technik', company: 'Hosting AG',
                    email: 'doris@example.com', phone: '+49 30 1234567', notes: 'Nur vormittags anrufen.',
                    additional_details: [{ 'kind' => 'phone', 'label' => 'Mobil', 'value' => '+49 170 1234567' }])
  end

  before do
    create(:project_permission, user: viewer, project: project, tickets_access: :read_only, meetings_access: :read_only)
    create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
    create(:project_permission, user: stranger, project: hidden_project, tickets_access: :read_only)
  end

  def lookup(user = viewer)
    described_class.new(viewer: user, organisation: organisation)
  end

  def names(page)
    page.entries.map(&:plain_name)
  end

  describe '#allowed?' do
    it 'is the people right: with view_people yes, without no' do
      expect(lookup.allowed?).to be true
      expect(lookup(colleague).allowed?).to be false
    end

    it 'holds for manage_people, which implies view_people' do
      expect(lookup(member('Mona', 'Manager', role: role_with('manage_people'))).allowed?).to be true
    end

    it 'holds for an account admin without a people row' do
      admin = member('Ada', 'Admin', role: create(:role, organisation: organisation, title: 'account_admin'))

      expect(lookup(admin).allowed?).to be true
    end

    it 'is false for a deactivated member who still holds the right' do
      Membership.find_by(user: viewer, organisation: organisation).update!(active: false)

      expect(lookup(User.find(viewer.id)).allowed?).to be false
    end
  end

  describe '#find' do
    it 'lists everyone the viewer sees, sorted by name, with the true total' do
      page = lookup.find(limit: 10)

      expect(names(page)).to eq(['Carl Kollege', 'Doris Dienstleister', 'Vera Viewer'])
      expect(page.total).to eq(3)
    end

    # The page's own search (People::Directory#matches?), not a second one.
    it 'searches as the people page does' do
      directory = People::Directory.new(viewer: viewer, organisation: organisation, query: 'techn')

      expect(names(lookup.find(query: 'techn', limit: 10))).to eq(directory.entries.map(&:plain_name))
      expect(names(lookup.find(query: 'techn', limit: 10))).to eq(['Doris Dienstleister'])
    end

    it 'filters by kind' do
      expect(names(lookup.find(kind: 'members', limit: 10))).to eq(['Carl Kollege', 'Vera Viewer'])
      expect(names(lookup.find(kind: 'contacts', limit: 10))).to eq(['Doris Dienstleister'])
    end

    it 'reads a blank kind as all' do
      expect(lookup.find(kind: '', limit: 10).total).to eq(3)
      expect(lookup.find(kind: nil, limit: 10).total).to eq(3)
    end

    # The page reads an unknown kind as "all"; a program would believe in a filter it never set.
    it 'refuses a kind it does not know, with the one wording all adapters show' do
      expect { lookup.find(kind: 'member', limit: 10) }
        .to raise_error(People::Lookup::InvalidArgument, 'kind must be one of: all, members, contacts')
    end

    it 'cuts at limit from offset, and counts what matched before the cut' do
      page = lookup.find(limit: 1, offset: 1)

      expect(names(page)).to eq(['Doris Dienstleister'])
      expect(page.total).to eq(3)
      expect(lookup.find(limit: 2, offset: 3).entries).to eq([])
    end

    it 'leaves out a member of a project the viewer cannot see, and that member\'s row' do
      create(:person, organisation: organisation, user: stranger, name: 'Sven Fremd')

      expect(names(lookup.find(limit: 10))).not_to include('Sven Fremd')
      expect(names(lookup.find(limit: 10))).to include('Doris Dienstleister')
    end

    it 'attaches the last contact to each entry' do
      meeting = create(:meeting, organisation: organisation, project: project, occurred_at: 3.days.ago)
      create(:meeting_participant, meeting: meeting, person: contact, display_name: 'Gast')

      entry = lookup.find(query: 'doris', limit: 10).entries.first

      expect(entry.last_contact.kind).to eq(:meeting)
    end

    it 'refuses without the people right, before it reads anything' do
      allow(People::Directory).to receive(:new).and_call_original

      expect { lookup(colleague).find(limit: 10) }.to raise_error(People::Lookup::Refused)
      expect(People::Directory).not_to have_received(:new)
    end

    it 'refuses the right before it looks at the kind' do
      expect { lookup(colleague).find(kind: 'member', limit: 10) }.to raise_error(People::Lookup::Refused)
    end

    it 'refuses a deactivated member who still holds the right' do
      Membership.find_by(user: viewer, organisation: organisation).update!(active: false)

      expect { lookup(User.find(viewer.id)).find(limit: 10) }.to raise_error(People::Lookup::Refused)
    end
  end

  describe '#entry' do
    it 'reads a contact by "person:<uuid>", with its last contact' do
      meeting = create(:meeting, organisation: organisation, project: project, occurred_at: 2.days.ago)
      create(:meeting_participant, meeting: meeting, person: contact, display_name: 'Gast')

      entry = lookup.entry("person:#{contact.id}")

      expect(entry.person).to eq(contact)
      expect(entry.last_contact.kind).to eq(:meeting)
    end

    it 'reads a member by "member:<uuid>", also without a row of their own' do
      entry = lookup.entry("member:#{colleague.id}")

      expect(entry).to be_member
      expect(entry.user).to eq(colleague)
      expect(entry.person).to be_nil
    end

    # Unknown, foreign and invisible: one answer, nothing tells which ids exist. Five lookups
    # in a row read the directory five times from one line, which Prosopite counts as an N+1;
    # a request reads it once.
    it 'answers nil for an unknown id, a person of another organisation and one the viewer may not see' do
      foreign = ActsAsTenant.with_tenant(other_organisation) { create(:person, organisation: other_organisation) }
      hidden_row = create(:person, organisation: organisation, user: stranger, name: 'Sven Fremd')

      Prosopite.pause do
        ["person:#{SecureRandom.uuid}", "member:#{SecureRandom.uuid}", "person:#{foreign.id}",
         "person:#{hidden_row.id}", "member:#{stranger.id}"].each do |id|
          expect(lookup.entry(id)).to be_nil, id
        end
      end
    end

    ['abc', 'person:abc', 'member:', 'new', '12345', ''].each do |id|
      it "refuses #{id.inspect} as an id of the wrong shape" do
        expect { lookup.entry(id) }.to raise_error(People::Lookup::InvalidArgument)
      end
    end

    it 'refuses without the people right, before it reads anything, whatever the id' do
      allow(People::Directory).to receive(:new).and_call_original

      expect { lookup(colleague).entry("person:#{contact.id}") }.to raise_error(People::Lookup::Refused)
      expect { lookup(colleague).entry('abc') }.to raise_error(People::Lookup::Refused)
      expect(People::Directory).not_to have_received(:new)
    end
  end

  describe '.row and .card' do
    let(:entry) { lookup.entry("person:#{contact.id}") }

    it 'gives a row who it is and what they do, never contact details or notes' do
      expect(described_class.row(entry).keys)
        .to eq(%i[id name kind function department company last_contact])
      expect(described_class.row(entry)).to include(id: "person:#{contact.id}", name: 'Doris Dienstleister', kind: 'contact')
    end

    it 'gives a card the row plus how to reach the person, without notes unless asked' do
      expect(described_class.card(entry).keys)
        .to eq(%i[id name kind function department company last_contact salutation email phone additional_details])
      expect(described_class.card(entry)).to include(email: 'doris@example.com', phone: '+49 30 1234567',
                                                     additional_details: [{ label: 'Mobil', value: '+49 170 1234567' }])
    end

    it 'adds the stored notes when asked, and nothing else' do
      card = described_class.card(entry, notes: true)

      expect(card.keys - described_class.card(entry).keys).to eq([:notes])
      expect(card[:notes]).to eq('Nur vormittags anrufen.')
    end

    it 'answers blank notes and a member without a row with null notes' do
      contact.update!(notes: '   ')

      expect(described_class.card(lookup.entry("person:#{contact.id}"), notes: true)[:notes]).to be_nil
      expect(described_class.card(lookup.entry("member:#{colleague.id}"), notes: true)[:notes]).to be_nil
    end

    # As on the people page: a member's name and email are the account's, the rest is the row's.
    it 'takes a member\'s name and email from the account, the notes from the row' do
      create(:person, organisation: organisation, user: colleague, name: 'C. Kollege (alt)', email: 'alt@example.com',
                      notes: 'Bevorzugt Mail.')

      card = described_class.card(lookup.entry("member:#{colleague.id}"), notes: true)

      expect(card).to include(id: "member:#{colleague.id}", name: 'Carl Kollege', email: 'carl@example.com',
                              notes: 'Bevorzugt Mail.')
    end
  end

  # E1 of S3b: the directory and the last contact read across the whole organisation, so only
  # a token that reaches every project of it may open them.
  describe '.for_token' do
    let(:reach) do
      PersonalAccessToken::Reach.new(project_ids_by_organisation: { organisation.id => nil,
                                                                    other_organisation.id => [project.id] })
    end

    def for_token(organisation_id)
      described_class.for_token(reach: reach, viewer: viewer, organisation_id: organisation_id)
    end

    it 'opens the directory of an organisation whose every project the token reaches' do
      found = for_token(organisation.id)

      expect(found.organisation).to eq(organisation)
      expect(found.find(limit: 10).total).to eq(3)
    end

    it 'takes the id in any spelling the UUID format allows' do
      expect(for_token(organisation.id.upcase)&.organisation).to eq(organisation)
      expect(for_token(organisation.id.delete('-'))&.organisation).to eq(organisation)
    end

    it 'opens nothing for an organisation the token reaches only in some projects' do
      expect(for_token(other_organisation.id)).to be_nil
    end

    it 'opens nothing for an organisation outside the token, a missing one or a malformed id' do
      outside = create(:organisation)

      [outside.id, SecureRandom.uuid, 'oops', '', nil].each do |id|
        expect(for_token(id)).to be_nil, id.inspect
      end
    end
  end
end
