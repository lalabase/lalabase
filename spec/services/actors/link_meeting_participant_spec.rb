# frozen_string_literal: true

require 'rails_helper'

# Linking a meeting participant to a row of the people directory (S2b). The
# actor resolves every id itself: the participant through the locked meeting,
# the person and the member through what the writer may see in the directory.
# One key per participant: a member is linked by user_id, a contact by person_id.
RSpec.describe Actors::LinkMeetingParticipant, :ci_guard do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:project) { create(:project, organisation: organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE) }
  let(:writer) { member(role: admin_role, first_name: 'Anna') }
  let(:meeting) { create(:meeting, organisation: organisation, project: project) }
  let!(:participant) { create(:meeting_participant, meeting: meeting, display_name: 'J. Weber (Hoster)') }
  let!(:contact) { create(:person, organisation: organisation, name: 'Jonas Weber') }

  def member(role: create(:role, organisation: organisation), first_name: 'Mia', org: organisation, active: true)
    user = create(:user, first_name: first_name, last_name: "Beispiel#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: org, role: role, active: active)
    User.find(user.id)
  end

  def role_with(*actions)
    role = create(:role, organisation: organisation)
    actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
    role
  end

  def link(user: writer, participant_id: participant.id, authorized_project: project, **choice)
    described_class.call(meeting: meeting, project: authorized_project, participant_id: participant_id,
                         current_user: user, **choice)
  end

  describe 'linking a contact' do
    it 'sets person_id and leaves user_id empty' do
      result = link(person_id: contact.id)

      expect(result).to be_success
      expect(result.resource).to eq(participant)
      expect(participant.reload.person_id).to eq(contact.id)
      expect(participant.user_id).to be_nil
      expect(participant.display_name).to eq('J. Weber (Hoster)')
    end

    it 'moves a linked contact participant to another contact' do
      other = create(:person, organisation: organisation, name: 'Jana Weber')
      link(person_id: contact.id)

      expect(link(person_id: other.id)).to be_success
      expect(participant.reload.person_id).to eq(other.id)
    end

    it 'writes no activity for the person' do
      expect { link(person_id: contact.id) }.not_to(change { Activity.where(trackable: contact).count })
    end

    it 'treats the row of a former member as a contact (person_id)' do
      former = member
      row = create(:person, organisation: organisation, name: 'Fritz Frueher', user: former)
      Membership.where(user: former, organisation: organisation).update_all(active: false)

      expect(link(person_id: row.id)).to be_success
      expect(participant.reload.person_id).to eq(row.id)
      expect(participant.user_id).to be_nil
    end
  end

  describe 'linking a member' do
    let(:colleague) { member(first_name: 'Carl') }

    it 'sets user_id and leaves person_id empty, by member id' do
      expect(link(member_id: colleague.id)).to be_success
      expect(participant.reload.user_id).to eq(colleague.id)
      expect(participant.person_id).to be_nil
    end

    it 'sets user_id when the chosen person row belongs to an active member' do
      row = create(:person, organisation: organisation, name: colleague.display_name, user: colleague)
      link(person_id: contact.id)

      expect(link(person_id: row.id)).to be_success
      expect(participant.reload.user_id).to eq(colleague.id)
      expect(participant.person_id).to be_nil
    end

    it 'refuses a member who already takes part in the meeting, changing nothing' do
      create(:meeting_participant, meeting: meeting, display_name: colleague.display_name, user: colleague)

      result = link(member_id: colleague.id)

      expect(result).not_to be_success
      expect(result.code).to eq(:member_already_participant)
      expect(result.errors).to eq([I18n.t('services.actors.link_meeting_participant.member_already_participant')])
      expect(participant.reload.user_id).to be_nil
    end
  end

  describe 'a participant that is a member' do
    it 'is not linked again (its account is the link)' do
      colleague = member(first_name: 'Carl')
      participant.update!(user: colleague)

      result = link(person_id: contact.id)

      expect(result.code).to eq(:member_participant)
      expect(participant.reload.person_id).to be_nil
    end
  end

  describe 'unlinking' do
    it 'sets person_id to nil and keeps the row and its name' do
      link(person_id: contact.id)

      expect(link(unlink: true)).to be_success
      expect(participant.reload.person_id).to be_nil
      expect(participant.display_name).to eq('J. Weber (Hoster)')
    end

    it 'leaves the account of a member participant alone' do
      colleague = member(first_name: 'Carl')
      participant.update!(user: colleague)

      expect(link(unlink: true).code).to eq(:member_participant)
      expect(participant.reload.user_id).to eq(colleague.id)
    end
  end

  describe 'creating a person and linking it' do
    it 'creates the row with the given name and links it in one step' do
      result = nil
      expect { result = link(new_person: { name: 'J. Weber' }) }.to change(Person, :count).by(1)

      expect(result).to be_success
      created = Person.order(:created_at).last
      expect(created.name).to eq('J. Weber')
      expect(created.creator).to eq(writer)
      expect(participant.reload.person_id).to eq(created.id)
    end

    it 'creates nothing when the name is blank' do
      result = nil
      expect { result = link(new_person: { name: ' ' }) }.not_to change(Person, :count)

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(participant.reload.person_id).to be_nil
    end

    it 'creates nothing when the link fails afterwards (one transaction)' do
      allow_any_instance_of(MeetingParticipant).to receive(:update!).and_raise(Actors::ActorError, 'link failed')

      result = nil
      expect { result = link(new_person: { name: 'J. Weber' }) }.not_to change(Person, :count)
      expect(result.errors).to eq(['link failed'])
    end

    it 'needs manage_people' do
      viewer = member(role: role_with('view_people'))

      result = nil
      expect { result = link(user: viewer, new_person: { name: 'J. Weber' }) }.not_to change(Person, :count)
      expect(result.code).to eq(:not_allowed)
    end

    it 'is allowed with manage_people' do
      manager = member(role: role_with('manage_people'))

      expect(link(user: manager, new_person: { name: 'J. Weber' })).to be_success
    end
  end

  describe 'what the writer cannot reach' do
    it 'refuses without a choice' do
      expect(link.code).to eq(:nothing_picked)
    end

    it 'does not find a person of another organisation' do
      foreign = ActsAsTenant.with_tenant(create(:organisation)) { create(:person, name: 'Jonas Weber') }

      expect(link(person_id: foreign.id).code).to eq(:not_found)
      expect(participant.reload.person_id).to be_nil
    end

    it 'does not find a person without view_people' do
      outsider = member

      expect(link(user: outsider, person_id: contact.id).code).to eq(:not_found)
      expect(participant.reload.person_id).to be_nil
    end

    it 'does not find the row of a member the writer may not see' do
      # Members see only colleagues of projects they share (MembershipPolicy::Scope).
      limited = member(role: role_with('view_people'))
      hidden_member = member(first_name: 'Hanna')
      create(:project_permission, user: limited, project: project, meetings_access: :read_write)
      create(:project_permission, user: hidden_member, project: create(:project, organisation: organisation),
                                  tickets_access: :read_only)
      row = create(:person, organisation: organisation, name: hidden_member.display_name, user: hidden_member)

      expect(link(user: limited, person_id: row.id).code).to eq(:not_found)
      expect(link(user: limited, member_id: hidden_member.id).code).to eq(:not_found)
      expect(participant.reload.user_id).to be_nil
    end

    it 'does not find a member of another organisation' do
      stranger = member(org: create(:organisation))

      expect(link(member_id: stranger.id).code).to eq(:not_found)
    end

    it 'does not find a participant of another meeting' do
      other_meeting = create(:meeting, organisation: organisation, project: project)
      other = create(:meeting_participant, meeting: other_meeting, display_name: 'Jonas Weber')

      expect(link(participant_id: other.id, person_id: contact.id).code).to eq(:not_found)
      expect(other.reload.person_id).to be_nil
    end

    it 'treats a meeting moved out of the authorized project as gone' do
      target = create(:project, organisation: organisation)
      meeting.update_columns(project_id: target.id)

      result = link(person_id: contact.id)

      expect(result.code).to eq(:not_found)
      expect(participant.reload.person_id).to be_nil
    end

    it 'takes the meeting lock' do
      expect(meeting).to receive(:lock_in_project!).with(project.id).and_call_original

      link(person_id: contact.id)
    end
  end
end
