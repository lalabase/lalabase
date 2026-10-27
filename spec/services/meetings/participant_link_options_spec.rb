# frozen_string_literal: true

require 'rails_helper'

# The lines of the link dialog (S2b, E6): suggestions first, then the search,
# and a refused pick drawn again once. Read from the viewer's directory.
RSpec.describe Meetings::ParticipantLinkOptions do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:admin) do
    create(:user, first_name: 'Anna', last_name: 'Admin').tap do |user|
      role = create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE)
      create(:membership, user: user, organisation: organisation, role: role)
    end
  end
  let(:meeting) { create(:meeting, organisation: organisation, project: create(:project, organisation: organisation)) }
  let(:participant) { create(:meeting_participant, meeting: meeting, display_name: 'J. Weber (Hoster)') }
  let!(:same_surname) { create(:person, organisation: organisation, name: 'Jonas Weber') }
  let!(:other) { create(:person, organisation: organisation, name: 'Anton Anders') }

  def lines(query: '', limit: 20, choice: nil)
    described_class.new(viewer: admin, organisation: organisation, participant: participant,
                        query: query, limit: limit, choice: choice).lines
  end

  def people(found)
    found.map { |line| [line.entry.person&.name || line.entry.user.display_name, line.suggested?] }
  end

  it 'puts the suggestions first, marked, and lists each person once' do
    expect(people(lines)).to eq([['Jonas Weber', true], ['Anna Admin', false], ['Anton Anders', false]])
  end

  it 'suggests nothing while searching, and lists only what the search finds' do
    expect(people(lines(query: 'weber'))).to eq([['Jonas Weber', false]])
  end

  it 'lists at most limit people besides the suggestions' do
    expect(people(lines(limit: 1))).to eq([['Jonas Weber', true], ['Anna Admin', false]])
  end

  describe 'a refused pick' do
    it 'comes back ahead of the others when it lies past the limit' do
      expect(people(lines(limit: 0, choice: "person:#{other.id}"))).to eq([['Jonas Weber', true], ['Anton Anders', false]])
    end

    it 'stays once where it is when it is a suggestion or already listed' do
      expect(lines(choice: "person:#{same_surname.id}").count { |line| line.entry.person == same_surname }).to eq(1)
      expect(lines(choice: "person:#{other.id}").count { |line| line.entry.person == other }).to eq(1)
    end

    it 'comes back as a member too' do
      expect(people(lines(limit: 0, choice: "member:#{admin.id}"))).to eq([['Jonas Weber', true], ['Anna Admin', false]])
    end

    it 'is not drawn when the viewer may not see it, or the value is no pick' do
      foreign = ActsAsTenant.with_tenant(create(:organisation)) { create(:person, name: 'Fremde Weber') }

      expect(people(lines(limit: 0, choice: "person:#{foreign.id}"))).to eq([['Jonas Weber', true]])
      expect(people(lines(limit: 0, choice: 'person:nonsense'))).to eq([['Jonas Weber', true]])
    end
  end
end
