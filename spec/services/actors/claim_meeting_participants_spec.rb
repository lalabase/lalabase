# frozen_string_literal: true

require 'rails_helper'

# Actors::ClaimMeetingParticipants — links external participations to an org member
# (Tier 1). Intent per describe:
#  - happy path: every reachable external row gets the member's user_id, the count is
#    reported, and display_name stays a snapshot.
#  - unique-index skip: a meeting that already links the member is skipped, NOT
#    linked again — otherwise the partial index (meeting_id, user_id) raises.
#  - scope: rows in non-writable projects are never touched.
#  - tamper guards: a non-member or inactive target fails cleanly and links nothing.
RSpec.describe Actors::ClaimMeetingParticipants do
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

  def member(active: true, first: 'Karl', last: 'Krause')
    person = create(:user, first_name: first, last_name: last)
    create(:membership, user: person, organisation: organisation,
                        role: create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation), active: active)
    person
  end

  # An external participant (user_id nil) in a fresh meeting of `project`.
  def external_row(project, name)
    meeting = create(:meeting, project: project, organisation: organisation, creator: actor)
    create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: name)
  end

  it 'links every reachable external participation and reports the count' do
    target = member
    row_a = external_row(writable_project, 'Karl Krause')
    row_b = external_row(writable_project, 'Karl Krause')

    claim = described_class.new(user: target, normalized_name: 'Karl Krause', current_user: actor)
    result = claim.call

    expect(result.success).to be(true)
    expect(claim.linked_count).to eq(2)
    # Single query for both rows (two identical .reload calls would trip Prosopite).
    rows = MeetingParticipant.where(id: [row_a.id, row_b.id])
    expect(rows.map(&:user_id)).to all(eq(target.id))
    expect(rows.map(&:display_name)).to all(eq('Karl Krause')) # snapshot untouched
  end

  it 'keeps display_name as a snapshot (does not overwrite with the member spelling)' do
    target = member(first: 'Karl', last: 'Krause') # display "Karl Krause"
    row = external_row(writable_project, 'karl krause') # different spelling, same key

    described_class.new(user: target, normalized_name: 'Karl Krause', current_user: actor).call

    row.reload
    expect(row.user_id).to eq(target.id)
    expect(row.display_name).to eq('karl krause')
  end

  it 'matches across umlaut spellings (member "Jörg Groß" ~ external "Joerg Gross")' do
    target = member(first: 'Jörg', last: 'Groß')
    row = external_row(writable_project, 'Joerg Gross')

    described_class.new(user: target, normalized_name: MeetingParticipant.normalize_name('Jörg Groß'),
                        current_user: actor).call

    expect(row.reload.user_id).to eq(target.id)
  end

  it 'skips a meeting that already links the member — no unique-index violation' do
    target = member
    meeting = create(:meeting, project: writable_project, organisation: organisation, creator: actor)
    # Same meeting: an external "Karl Krause" AND the member already linked under a
    # DIFFERENT name ("Karl" → different normalized_name, so both rows are legal).
    external = create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: 'Karl Krause')
    create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: 'Karl', user: target)

    claim = described_class.new(user: target, normalized_name: 'Karl Krause', current_user: actor)
    result = claim.call

    expect(result.success).to be(true) # did not raise RecordNotUnique
    expect(claim.linked_count).to eq(0)
    expect(external.reload.user_id).to be_nil
  end

  it 'links reachable rows but skips only the already-linked meeting (mixed batch)' do
    target = member
    reachable = external_row(writable_project, 'Karl Krause')
    blocked_meeting = create(:meeting, project: writable_project, organisation: organisation, creator: actor)
    blocked = create(:meeting_participant, meeting: blocked_meeting, organisation: organisation, display_name: 'Karl Krause')
    create(:meeting_participant, meeting: blocked_meeting, organisation: organisation, display_name: 'Karl', user: target)

    claim = described_class.new(user: target, normalized_name: 'Karl Krause', current_user: actor)
    claim.call

    expect(claim.linked_count).to eq(1)
    # One query for both rows (avoid two identical .reload → Prosopite N+1).
    states = MeetingParticipant.where(id: [reachable.id, blocked.id]).pluck(:id, :user_id).to_h
    expect(states[reachable.id]).to eq(target.id)
    expect(states[blocked.id]).to be_nil
  end

  it 'leaves external rows in non-writable projects untouched' do
    target = member
    row = external_row(readonly_project, 'Karl Krause')

    claim = described_class.new(user: target, normalized_name: 'Karl Krause', current_user: actor)
    result = claim.call

    expect(result.success).to be(true)
    expect(claim.linked_count).to eq(0)
    expect(row.reload.user_id).to be_nil
  end

  it 'fails for a target that is not an org member (tamper guard) and links nothing' do
    outsider = create(:user, first_name: 'Out', last_name: 'Sider') # never made a member
    row = external_row(writable_project, 'Out Sider')

    result = described_class.new(user: outsider, normalized_name: 'Out Sider', current_user: actor).call

    expect(result.success).to be(false)
    expect(row.reload.user_id).to be_nil
  end

  it 'fails for an inactive member (tamper guard) and links nothing' do
    inactive = member(active: false)
    row = external_row(writable_project, 'Karl Krause')

    result = described_class.new(user: inactive, normalized_name: 'Karl Krause', current_user: actor).call

    expect(result.success).to be(false)
    expect(row.reload.user_id).to be_nil
  end

  it 'turns a concurrent RecordNotUnique into a clean failure, not a raise-through' do
    target = member
    external_row(writable_project, 'Karl Krause')
    # Simulate the TOCTOU race: a concurrent write linked the member between the
    # skip-check and the UPDATE, so the partial (meeting_id, user_id) index bites.
    allow_any_instance_of(ActiveRecord::Relation)
      .to receive(:update_all).and_raise(ActiveRecord::RecordNotUnique.new('concurrent link'))

    result = nil
    expect { result = described_class.new(user: target, normalized_name: 'Karl Krause', current_user: actor).call }
      .not_to raise_error
    expect(result.success).to be(false)
  end
end
