# frozen_string_literal: true

require 'rails_helper'

# What: Lalabase::Tools::GetPerson -- the assistant reads one person of the directory
#       (People S3), with the contact details find_people leaves out.
# Type: Service spec against real rows.
# Why:  This is the call that sends a third person's email and phone to the AI provider.
#       The card carries exactly the fields of decision E2 and never the notes; the id
#       resolves only through the asker's People::Directory, so an id of another
#       organisation, of a person the asker may not see and an unknown id all answer the
#       same; the people right comes first; and the one citation carries the people area.
RSpec.describe Lalabase::Tools::GetPerson, :ci_guard do
  let(:organisation) { create(:organisation) }

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
                    email: 'doris@example.com', phone: '+49 30 1234567', notes: 'Geheime Notiz',
                    additional_details: [
                      { 'kind' => 'phone', 'label' => 'Mobil', 'value' => '+49 170 1234567' },
                      { 'kind' => 'url', 'label' => '', 'value' => 'https://example.com' }
                    ])
  end

  before do
    create(:project_permission, user: viewer, project: project, tickets_access: :read_only, meetings_access: :read_only)
    create(:project_permission, user: colleague, project: project, tickets_access: :read_only)
    create(:project_permission, user: stranger, project: hidden_project, tickets_access: :read_only)
  end

  def run(id, user: viewer)
    described_class.execute(args: { id: id }, context: Lalabase::Tools::Context.new(actor: user, organisation: organisation))
  end

  def card(result)
    JSON.parse(result.content)
  end

  describe 'contract metadata' do
    it 'is a read tool that needs the asker and one id' do
      expect(described_class.mutating?).to be false
      expect(described_class.requires_actor?).to be true
      expect(described_class.input_schema[:properties].keys).to eq([:id])
      expect(described_class.input_schema[:required]).to eq(['id'])
    end
  end

  describe 'the card' do
    # E2, pinned whole: a field added here goes to the AI provider. The notes are free text
    # about a third person and stay out (decision E2).
    it 'carries exactly the fields of E2, never the notes' do
      result = run("person:#{contact.id}")

      expect(card(result).keys).to contain_exactly('id', 'name', 'kind', 'salutation', 'function', 'department',
                                                   'company', 'email', 'phone', 'additional_details', 'last_contact')
      expect(card(result)).to include('id' => "person:#{contact.id}", 'name' => 'Doris Dienstleister',
                                      'kind' => 'contact', 'salutation' => 'Frau', 'function' => 'Leitung IT',
                                      'department' => 'Technik', 'company' => 'Hosting AG',
                                      'email' => 'doris@example.com', 'phone' => '+49 30 1234567',
                                      'last_contact' => nil)
      expect(result.content).not_to include('Geheime Notiz')
    end

    # A detail without a label is named by its kind, as the people page names it.
    it 'hands over the additional details as label and value' do
      details = card(run("person:#{contact.id}"))['additional_details']

      expect(details).to eq([{ 'label' => 'Mobil', 'value' => '+49 170 1234567' },
                             { 'label' => 'url', 'value' => 'https://example.com' }])
    end

    # As on the people page: an active member's name and email are the account's, the
    # other details come from the member's row.
    it 'takes the name and email of a member from the account' do
      create(:person, organisation: organisation, user: colleague, name: 'C. Kollege (alt)',
                      email: 'alt@example.com', phone: '+49 30 7654321')

      result = card(run("member:#{colleague.id}"))

      expect(result).to include('id' => "member:#{colleague.id}", 'name' => 'Carl Kollege', 'kind' => 'member',
                                'email' => 'carl@example.com', 'phone' => '+49 30 7654321')
    end

    it 'reads a member without a row of their own' do
      result = card(run("member:#{colleague.id}"))

      expect(result).to include('name' => 'Carl Kollege', 'email' => 'carl@example.com', 'phone' => nil,
                                'additional_details' => [])
    end

    it 'cites exactly the person, with the people area' do
      citation = { type: 'person', area: 'people', id: contact.id, name: 'Doris Dienstleister' }

      expect(run("person:#{contact.id}").citations).to eq([citation])
    end

    # E3 for the card too: date and kind, no title; an unreadable meeting never counts.
    def meeting_with_contact(project_for, at:)
      meeting = create(:meeting, organisation: organisation, project: project_for, occurred_at: at, title: 'Geheimes Treffen')
      create(:meeting_participant, meeting: meeting, person: contact, display_name: 'Gast')
    end

    it 'gives the last contact as date and kind only' do
      readable_at = 8.days.ago
      meeting_with_contact(project, at: readable_at)
      meeting_with_contact(hidden_project, at: 1.day.ago)

      result = run("person:#{contact.id}")

      expect(card(result)['last_contact']).to eq('on' => readable_at.in_time_zone.to_date.iso8601, 'kind' => 'meeting')
      expect(result.content).not_to include('Geheimes Treffen')
    end
  end

  # Unknown, foreign and invisible answer alike, word for word: the answer must not tell
  # which ids exist.
  describe 'an id the asker cannot read' do
    def expect_not_found(id)
      result = run(id)

      expect(result.error_code).to eq(:not_found)
      expect(result.error).to eq("No person found for #{id}. Use an id find_people returned.")
      expect(result.citations).to be_blank
    end

    it 'answers an unknown id as not found' do
      expect_not_found("person:#{SecureRandom.uuid}")
    end

    it 'answers the id of a person in another organisation the same' do
      other = create(:organisation)
      foreign = ActsAsTenant.with_tenant(other) { create(:person, organisation: other) }

      expect_not_found("person:#{foreign.id}")
    end

    it 'answers the row of a member the asker may not see the same' do
      row = create(:person, organisation: organisation, user: stranger, name: 'Sven Fremd')

      expect_not_found("person:#{row.id}")
    end

    it 'answers the account of a member the asker may not see the same' do
      expect_not_found("member:#{stranger.id}")
    end

    it 'answers a deactivated member by the account the same' do
      Membership.find_by(user: colleague, organisation: organisation).update!(active: false)

      expect_not_found("member:#{colleague.id}")
    end
  end

  describe 'an id that is no id' do
    %w[abc person:abc member: 12345].each do |id|
      it "refuses #{id.inspect} as invalid input" do
        result = run(id)

        expect(result.error_code).to eq(:invalid_input)
        expect(result.error).to include('find_people')
      end
    end

    it 'asks for the id when there is none' do
      expect(run('').error).to eq('id is required')
    end
  end

  describe 'rights' do
    it 'refuses without the people right, before it reads anything' do
      allow(People::Directory).to receive(:new).and_call_original

      result = run("person:#{contact.id}", user: colleague)

      expect(result.error_code).to eq(:refused)
      expect(result.error).to include('may not see the people directory')
      expect(People::Directory).not_to have_received(:new)
    end

    it 'refuses a deactivated member who still holds the right' do
      Membership.find_by(user: viewer, organisation: organisation).update!(active: false)

      expect(run("person:#{contact.id}").error_code).to eq(:refused)
    end
  end
end
