# frozen_string_literal: true

require 'rails_helper'

# Meetings::ParticipantClaimMatches — the live, read-only claim matcher. Intent per
# describe:
#  - happy path: an external name equal to an active member's, in a WRITABLE meeting,
#    surfaces once with the right meeting_count.
#  - name gate: members without a real name (email-prefix fallback) never match.
#  - write gate: only meetings the acting user may write are searched.
#  - rejection gate: an explicitly rejected (member, name) pair is suppressed.
#  - isolation: no reach into another organisation.
#  - shape: doppelgängers yield one suggestion each; no writable project → nothing.
RSpec.describe Meetings::ParticipantClaimMatches do
  let(:organisation) { create(:organisation) }
  let(:actor) { create(:user, first_name: 'Acting', last_name: 'Writer') }
  let(:writable_project) { create(:project, organisation: organisation) }
  let(:readonly_project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
    create(:membership, user: actor, organisation: organisation, role: role, active: true)
    create(:project_permission, user: actor, project: writable_project, meetings_access: 'read_write')
    create(:project_permission, user: actor, project: readonly_project, meetings_access: 'read_only')
  end

  after { ActsAsTenant.current_tenant = nil }

  def normalize(name)
    MeetingParticipant.normalize_name(name)
  end

  def named_member(first, last, org: organisation)
    member = create(:user, first_name: first, last_name: last)
    create(:membership, user: member, organisation: org,
                        role: create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: org), active: true)
    member
  end

  # Creates a meeting in `project` with a single EXTERNAL participant (user_id nil).
  def external_in(project, name, org: organisation)
    meeting = create(:meeting, project: project, organisation: org, creator: actor)
    create(:meeting_participant, meeting: meeting, organisation: org, display_name: name)
    meeting
  end

  subject(:matches) { described_class.new(user: actor, organisation: organisation).call }

  it 'matches an external participant to an active named member in a writable project' do
    member = named_member('Karl', 'Krause')
    external_in(writable_project, 'Karl Krause')

    expect(matches.size).to eq(1)
    match = matches.first
    expect(match.user).to eq(member)
    expect(match.normalized_name).to eq(normalize('Karl Krause'))
    expect(match.display_name).to eq('Karl Krause')
    expect(match.meeting_count).to eq(1)
  end

  it 'counts every writable meeting the external name appears in' do
    named_member('Karl', 'Krause')
    external_in(writable_project, 'Karl Krause')
    external_in(writable_project, 'Karl Krause')

    expect(matches.first.meeting_count).to eq(2)
  end

  it 'matches across umlaut spellings (member "Jörg" ~ external "Joerg")' do
    member = named_member('Jörg', 'Groß')
    external_in(writable_project, 'Joerg Gross')

    expect(matches.map(&:user)).to eq([member])
  end

  it 'ignores members without a real name (email-prefix fallback must not match)' do
    # display_name falls back to "karl" (email prefix); an external "karl" must NOT
    # be treated as this member.
    create(:user, first_name: '', last_name: '', email: 'karl@example.com').tap do |nameless|
      create(:membership, user: nameless, organisation: organisation,
                          role: create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation), active: true)
    end
    external_in(writable_project, 'karl')

    expect(matches).to be_empty
  end

  it 'ignores members whose membership is inactive' do
    inactive = create(:user, first_name: 'Karl', last_name: 'Krause')
    create(:membership, user: inactive, organisation: organisation,
                        role: create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation), active: false)
    external_in(writable_project, 'Karl Krause')

    expect(matches).to be_empty
  end

  it 'suppresses a pair the writer has explicitly rejected' do
    member = named_member('Karl', 'Krause')
    external_in(writable_project, 'Karl Krause')
    MeetingParticipantClaimRejection.create!(user: member, normalized_name: normalize('Karl Krause'))

    expect(matches).to be_empty
  end

  it 'still matches when a DIFFERENT member with the same name was rejected' do
    kept = named_member('Karl', 'Krause')
    other = named_member('Karl', 'Krause')
    external_in(writable_project, 'Karl Krause')
    MeetingParticipantClaimRejection.create!(user: other, normalized_name: normalize('Karl Krause'))

    expect(matches.map(&:user)).to eq([kept])
  end

  it 'only searches meetings the acting user may WRITE (read-only project excluded)' do
    named_member('Karl', 'Krause')
    external_in(readonly_project, 'Karl Krause') # actor is read-only here

    expect(matches).to be_empty
  end

  it 'never matches an already-linked (internal) participant' do
    member = named_member('Karl', 'Krause')
    meeting = create(:meeting, project: writable_project, organisation: organisation, creator: actor)
    create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: 'Karl Krause', user: member)

    expect(matches).to be_empty
  end

  # One key per participant (S2b): a name linked to a contact of the people
  # directory is that contact, not a free name a member could claim.
  it 'never matches a participant linked to a contact' do
    named_member('Karl', 'Krause')
    meeting = external_in(writable_project, 'Karl Krause')
    meeting.meeting_participants.first.update!(person: create(:person, organisation: organisation, name: 'Karl Krause'))

    expect(matches).to be_empty
  end

  it 'returns one suggestion per member for real doppelgängers' do
    twin_a = named_member('Karl', 'Krause')
    twin_b = named_member('Karl', 'Krause')
    external_in(writable_project, 'Karl Krause')

    expect(matches.map(&:user)).to contain_exactly(twin_a, twin_b)
    expect(matches.map(&:meeting_count)).to eq([1, 1])
  end

  it 'returns nothing for a user without any writable meetings project' do
    reader = create(:user, first_name: 'Rita', last_name: 'Reader')
    create(:membership, user: reader, organisation: organisation,
                        role: create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation), active: true)
    create(:project_permission, user: reader, project: writable_project, meetings_access: 'read_only')
    named_member('Karl', 'Krause')
    external_in(writable_project, 'Karl Krause')

    expect(described_class.new(user: reader, organisation: organisation).call).to eq([])
  end

  describe 'cross-organisation isolation' do
    let(:other_org) { create(:organisation) }

    it 'never reaches a member or external name from another organisation' do
      ActsAsTenant.with_tenant(other_org) do
        foreign_project = create(:project, organisation: other_org)
        named_member('Karl', 'Krause', org: other_org)
        external_in(foreign_project, 'Karl Krause', org: other_org)
      end

      expect(matches).to be_empty
    end
  end
end
