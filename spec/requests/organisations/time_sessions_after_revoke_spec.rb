# frozen_string_literal: true

require 'rails_helper'

# What: taking someone off a project also takes away their time rights there.
# Why: until 27.09.2026 the time rights (TimeSessionPermission) were a second
#   grant that nothing removed. Actors::RevokeProjectMember dropped or blocked
#   the ProjectPermission, but ProjectPolicy#area_access?(:time_sessions) and
#   TimeSessions::ViewingScope read only the time row. A removed member kept
#   reading every colleague's bookings (can_view_all) and kept booking time.
#   Now the row goes with the project access, and a row without a live
#   ProjectPermission behind it counts for nothing
#   (TimeSessionPermission.backed_by_project_access).
RSpec.describe 'Time rights after leaving a project', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:plain_role) { create(:role, organisation: organisation, title: 'member') }
  let(:global_reader_role) do
    role = create(:role, organisation: organisation, title: 'tickets_reader')
    create(:project_read_permission, role: role, area: 'tickets')
    role
  end

  let(:project) { create(:project, organisation: organisation) }
  let(:other_project) { create(:project, organisation: organisation) }
  let(:admin) { member_in(admin_role) }
  let(:colleague) { member_in(plain_role) }

  let(:foreign_booking_text) { 'Colleague booked this in secret' }

  before do
    ActsAsTenant.current_tenant = organisation
    Prosopite.pause
  end

  after do
    Prosopite.resume
    ActsAsTenant.current_tenant = nil
  end

  def member_in(role)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: true)
    user
  end

  # A project member who may read and book every booking of the project.
  def time_member(user, on: project)
    create(:project_permission, user: user, project: on, tickets_access: :read_write)
    create(:time_session_permission, user: user, project: on, can_view_all: true, can_create_own: true)
  end

  # Today on purpose: the factory's occurred_on sequence drifts into the future
  # over a long run, out of the list's period.
  def colleague_booking
    create(:time_session, project: project, creator: colleague, description: foreign_booking_text,
                          occurred_on: Time.current)
  end

  def revoke(user, on: project)
    result = Actors::RevokeProjectMember.call(project: on, user: user, current_user: admin)
    expect(result).to be_success
  end

  # The list redirects a reader without any time right, and "not included" on a
  # redirect proves nothing. A second project keeps the page rendering.
  def time_list_as(user)
    time_member(user, on: other_project) unless TimeSessionPermission.exists?(user: user, project: other_project)
    sign_in user
    get organisation_time_sessions_path(organisation)
    expect(response).to have_http_status(:ok)
    response.body
  end

  def book_as(user, on: project)
    sign_in user
    attributes = { duration_string: '0:30', occurred_on: Date.current.to_s, description: 'Booked after removal' }
    expect do
      post organisation_project_time_sessions_path(organisation, on), params: { time_session: attributes }
    end.not_to(change { ActsAsTenant.with_tenant(organisation) { TimeSession.count } })
  end

  def allowed?(user, action, on: project)
    ProjectPolicy.new(user, on.reload).area_access?(:time_sessions, action)
  end

  shared_examples 'a member without time rights on the project' do
    it 'drops the time row' do
      expect(TimeSessionPermission.where(user: member, project: project)).not_to exist
    end

    it 'grants neither reading nor booking time there' do
      expect(allowed?(member, :read)).to be(false)
      expect(allowed?(member, :write)).to be(false)
      expect(TimeSessions::ViewingScope.call(user: member, project: project).tier).to eq(:none)
    end

    it 'no longer lists the colleague booking' do
      expect(time_list_as(member)).not_to include(foreign_booking_text)
    end

    it 'refuses a new booking' do
      book_as(member)
    end
  end

  context 'when the member had no role right (release)' do
    let(:member) { member_in(plain_role) }

    before do
      time_member(member)
      colleague_booking
    end

    it 'lists the colleague booking while the member is on the project' do
      expect(time_list_as(member)).to include(foreign_booking_text)
    end

    context 'after the revoke' do
      before do
        time_member(member, on: other_project)
        revoke(member)
      end

      it_behaves_like 'a member without time rights on the project'

      it 'keeps the time rights of a project the member is still on' do
        expect(TimeSessionPermission.where(user: member, project: other_project)).to exist
        expect(allowed?(member, :read, on: other_project)).to be(true)
        expect(allowed?(member, :write, on: other_project)).to be(true)
      end
    end
  end

  context 'when a role right stood behind the grant (block)' do
    let(:member) { member_in(global_reader_role) }

    before do
      time_member(member)
      colleague_booking
      revoke(member)
    end

    it_behaves_like 'a member without time rights on the project'
  end

  context 'when the explicit grant is dropped without the actor' do
    let(:member) { member_in(plain_role) }

    before do
      time_member(member)
      colleague_booking
      ProjectPermission.find_by!(user: member, project: project).update!(deleted_at: Time.current)
    end

    it_behaves_like 'a member without time rights on the project'
  end

  context 'with a time row left over from before this fix' do
    let(:member) { member_in(plain_role) }

    before do
      time_member(member)
      colleague_booking
      # update_columns skips every callback: the shape an old revoke left behind.
      ProjectPermission.find_by!(user: member, project: project).update_columns(deleted_at: Time.current)
    end

    it 'still counts for nothing' do
      expect(TimeSessionPermission.where(user: member, project: project)).to exist
      expect(allowed?(member, :read)).to be(false)
      expect(allowed?(member, :write)).to be(false)
      expect(time_list_as(member)).not_to include(foreign_booking_text)
      book_as(member)
    end
  end

  context 'when the person leaves the organisation' do
    let(:member) { member_in(plain_role) }
    let(:foreign_org) { create(:organisation) }
    let(:foreign_project) { ActsAsTenant.with_tenant(foreign_org) { create(:project, organisation: foreign_org) } }

    before do
      time_member(member)
      ActsAsTenant.with_tenant(foreign_org) do
        create(:membership, user: member, organisation: foreign_org, active: true)
        time_member(member, on: foreign_project)
      end
    end

    it 'drops the time rows of this organisation only' do
      service = RemoveMembershipService.new(membership: member.memberships.find_by!(organisation: organisation), admin: admin)
      expect(service.call).to be(true)

      expect(TimeSessionPermission.where(user: member, project: project)).not_to exist
      expect(TimeSessionPermission.where(user: member, project: foreign_project)).to exist
    end
  end
end
