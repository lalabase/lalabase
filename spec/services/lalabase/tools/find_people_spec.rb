# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::FindPeople -- the assistant lists people of the directory (People S3).
# Type: Service spec against real rows (members, contacts, meetings).
# Why:  The tool hands third-party contact data to an AI provider, so what it may read is the
#       point: the people right first (refused without it, nothing read), the viewer's reach
#       of People::Directory (a member of a project the viewer cannot see is not there), the
#       page's own search, at most MAX_ENTRIES rows with the true total, the last contact as
#       date and kind only, and citations with the people area, so that an answer drawn on
#       the list stays with the asker.
RSpec.describe Lalabase::Tools::FindPeople, :ci_guard do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*actions)
    role = create(:role, organisation: organisation)
    actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
    role
  end

  def member(first, last, role: role_with, active: true)
    user = create(:user, first_name: first, last_name: last)
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
                    email: 'dd.kontakt@example.com', phone: '+49 30 1234567', notes: 'Geheime Notiz')
  end

  before do
    create(:project_permission, user: viewer, project: project, tickets_access: :read_only, meetings_access: :read_only)
    create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
    create(:project_permission, user: stranger, project: hidden_project, tickets_access: :read_only)
  end

  def run(user: viewer, **args)
    described_class.execute(args: args, context: Lalabase::Tools::Context.new(actor: user, organisation: organisation))
  end

  def payload(result)
    JSON.parse(result.content)
  end

  def names(result)
    payload(result)['data'].pluck('name')
  end

  describe 'contract metadata' do
    it 'is a read tool that needs the asker, with two optional arguments' do
      expect(described_class.mutating?).to be false
      expect(described_class.requires_actor?).to be true
      expect(described_class.input_schema[:properties].keys).to contain_exactly(:query, :kind)
      expect(described_class.input_schema[:properties][:kind][:enum]).to eq(People::Directory::KINDS)
      expect(described_class.input_schema[:required]).to eq([])
    end

    # The instructions, not the sentences around them: one short stem (the search is a part
    # of a field, so "Technik" never meets "Technische"), the company name, where
    # responsibility is written down, kind left out, no guessing, the way to the details.
    # The first run with a real model (28.10.2026) searched "Technik" among members only,
    # found nobody and said so, while the person stood there as a contact.
    it 'tells the model how to search and where the contact details are' do
      expect(described_class.description).to include('"techn"', 'company name', 'function and department',
                                                     'Leave kind out', 'never guess a person', 'get_person')
    end

    it 'lists at most twenty people' do
      expect(described_class::MAX_ENTRIES).to eq(20)
    end
  end

  describe 'search' do
    # The page's own match (People::Directory#matches?), umlaut-normalized: one example per
    # field, each a single call.
    {
      'dienstleister' => 'the name',
      'Frau Doris' => 'the salutation with the name',
      'leitung' => 'the function',
      'technik' => 'the department',
      'hosting' => 'the company',
      'dd.kontakt' => 'the email'
    }.each do |query, field|
      it "finds a person by #{field} (#{query})" do
        expect(names(run(query: query))).to eq(['Doris Dienstleister'])
      end
    end

    it 'matches umlauts the way the people page does' do
      create(:person, organisation: organisation, name: 'Jürgen Müller', function: nil, department: nil, company: nil)

      expect(names(run(query: 'mueller'))).to eq(['Jürgen Müller'])
    end

    it 'finds a member by the account name' do
      colleague

      expect(names(run(query: 'kollege'))).to eq(['Carl Kollege'])
    end

    # An empty list says what to try next, the way search_help names its second route: the
    # real model gave up after the first word that found nobody.
    it 'answers no match with an empty list and what to try next, not an error' do
      result = run(query: 'zzz')

      expect(result.success?).to be true
      expect(result.kind).to eq(:ok)
      expect(payload(result)).to eq('total' => 0, 'truncated' => false, 'data' => [],
                                    'next_step' => described_class::NO_MATCH_NEXT_STEP)
      expect(described_class::NO_MATCH_NEXT_STEP).to include('"techn"', 'company name', 'kind')
      expect(result.citations).to eq([])
    end

    it 'names no next step when it found people' do
      expect(payload(run(query: 'dienstleister')).keys).to contain_exactly('total', 'truncated', 'data')
    end
  end

  describe 'the kind filter' do
    it 'lists everyone the viewer sees by default, sorted by name' do
      expect(names(run)).to eq(['Carl Kollege', 'Doris Dienstleister', 'Vera Viewer'])
    end

    it 'lists the members only' do
      expect(names(run(kind: 'members'))).to eq(['Carl Kollege', 'Vera Viewer'])
    end

    it 'lists the contacts only' do
      expect(names(run(kind: 'contacts'))).to eq(['Doris Dienstleister'])
    end

    # The page maps an unknown kind to "all"; for the model that would be a filter it
    # believes it set and did not.
    it 'refuses a kind it does not know' do
      result = run(kind: 'member')

      expect(result.error_code).to eq(:invalid_input)
      expect(result.error).to include('all, members, contacts')
    end
  end

  describe 'the rows' do
    it 'carries exactly the list fields, never contact details or the notes' do
      row = payload(run(query: 'dienstleister'))['data'].first

      expect(row.keys).to contain_exactly('id', 'name', 'kind', 'function', 'department', 'company', 'last_contact')
      expect(row).to include('id' => "person:#{contact.id}", 'name' => 'Doris Dienstleister', 'kind' => 'contact',
                             'function' => 'Leitung IT', 'department' => 'Technik', 'company' => 'Hosting AG',
                             'last_contact' => nil)
    end

    it 'addresses a member by the account, with the name from the account' do
      create(:person, organisation: organisation, user: colleague, name: 'C. Kollege (alt)', function: 'Einkauf')

      row = payload(run(query: 'einkauf'))['data'].first

      expect(row).to include('id' => "member:#{colleague.id}", 'name' => 'Carl Kollege', 'kind' => 'member',
                             'function' => 'Einkauf')
    end
  end

  describe 'the limit' do
    def contacts(count)
      count.times { |index| create(:person, organisation: organisation, name: format('Zora Zusatz %02d', index)) }
    end

    it 'lists the first twenty by name and says how many there are' do
      contacts(21)

      result = payload(run(query: 'zusatz'))

      expect(result['data'].size).to eq(20)
      expect(result['data'].first['name']).to eq('Zora Zusatz 00')
      expect(result['total']).to eq(21)
      expect(result['truncated']).to be true
    end

    it 'is not truncated at exactly twenty' do
      contacts(20)

      result = payload(run(query: 'zusatz'))

      expect(result['data'].size).to eq(20)
      expect(result['truncated']).to be false
    end

    # Two visible members, Doris and the 21: the stranger's project is out of reach.
    it 'lists the first twenty by name without a query' do
      contacts(21)

      result = payload(run)

      expect(result['data'].size).to eq(20)
      expect(result['data'].first(3).pluck('name')).to eq(['Carl Kollege', 'Doris Dienstleister', 'Vera Viewer'])
      expect(result['total']).to eq(24)
      expect(result['truncated']).to be true
    end
  end

  describe 'rights' do
    # The same rule as the people page: MembershipPolicy::Scope for the member half, and the
    # member's row stays as hidden as the member.
    it 'leaves out a member of a project the viewer cannot see, and that member\'s row' do
      create(:person, organisation: organisation, user: stranger, name: 'Sven Fremd', function: 'Fremdes Projekt')

      result = run

      expect(names(result)).to include('Doris Dienstleister')
      expect(names(result)).not_to include('Sven Fremd')
      expect(result.content).not_to include('Fremdes Projekt')
    end

    it 'refuses without the people right, before it reads anything' do
      allow(People::Directory).to receive(:new).and_call_original

      result = run(user: colleague)

      expect(result.error_code).to eq(:refused)
      expect(result.error).to include('may not see the people directory')
      expect(People::Directory).not_to have_received(:new)
    end

    it 'refuses a deactivated member who still holds the right' do
      Membership.find_by(user: viewer, organisation: organisation).update!(active: false)

      expect(run.error_code).to eq(:refused)
    end
  end

  describe 'the last contact' do
    def meeting(project_for, at:, person: nil, user: nil)
      record = create(:meeting, organisation: organisation, project: project_for, occurred_at: at, title: 'Geheimes Treffen')
      create(:meeting_participant, meeting: record, person: person, user: user, display_name: 'Gast')
    end

    # E3: date and kind only, no meeting title. A meeting in a project the viewer may not
    # read never counts, even when it is the newer one (People::Contacts).
    it 'is the date and kind of the last readable meeting, nothing else' do
      readable_at = 8.days.ago
      meeting(project, at: readable_at, person: contact)
      meeting(hidden_project, at: 1.day.ago, person: contact)

      result = run(query: 'dienstleister')

      expect(payload(result)['data'].first['last_contact'])
        .to eq('on' => readable_at.in_time_zone.to_date.iso8601, 'kind' => 'meeting')
      expect(result.content).not_to include('Geheimes Treffen')
    end
  end

  describe 'citations' do
    # Without a citation an answer drawn only on the list would carry no area: it would count
    # as content-free and reach a non-owner and the broadcast unredacted.
    it 'cites the first people it lists, each with the people area' do
      create_list(:person, 6, organisation: organisation)

      result = run

      expect(result.citations.size).to eq(described_class::MAX_CITATIONS)
      expect(result.citations).to all(include(type: 'person', area: 'people'))
      carl = { type: 'person', area: 'people', id: colleague.id, member_id: colleague.id, name: 'Carl Kollege' }
      doris = { type: 'person', area: 'people', id: contact.id, name: 'Doris Dienstleister' }
      expect(result.citations.first(2)).to eq([carl, doris])
    end
  end
end
