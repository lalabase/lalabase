# frozen_string_literal: true

require 'rails_helper'

# What: an archived project is closed to everyone but the account admins.
#   Members keep reading their OWN booked hours there (read only); nothing
#   else of the project is readable or writable for them.
# Why: until 27.09.2026 only ProjectPolicy#show? knew about the archive. The
#   area gate (ProjectPolicy#area_access?), AccessCheck::ProjectAccessService
#   and its id lists did not, so a direct link opened, and saved, tickets,
#   notes and documents of an archived project (audit of 26.09.2026). The rule
#   now lives in the service, with the time domain following it.
RSpec.describe 'Access to an archived project', :ci_guard, type: :request do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:plain_role) { create(:role, organisation: organisation, title: 'member') }
  let(:global_role) do
    role = create(:role, organisation: organisation, title: 'reads_everything')
    %w[tickets notes documents].each { |area| create(:project_write_permission, role: role, area: area) }
    role
  end

  let(:project) { create(:project, organisation: organisation) }
  let(:admin) { member_in(admin_role) }
  let(:member) { member_in(plain_role) }
  let(:colleague) { member_in(plain_role) }

  let(:ticket) { create(:ticket, project: project, organisation: organisation, title: 'Original title') }
  let(:note) { create(:note, project: project, organisation: organisation, creator: admin, title: 'Original note') }
  let(:document) do
    doc = create(:document, project: project, organisation: organisation, creator: admin)
    doc.update!(current_version: create(:document_version, document: doc, organisation: organisation, title: 'File'))
    doc
  end

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

  def grant_everything(user)
    create(:project_permission, user: user, project: project,
                                **ProjectPermission.access_areas.to_h { |area| [:"#{area}_access", :read_write] })
  end

  def archive!
    project.archive!(admin)
  end

  def ok?(path)
    get path
    response.status == 200
  end

  def ticket_path = organisation_project_ticket_path(organisation, project, ticket)
  def note_path(**frame) = organisation_project_note_path(organisation, project, note, **frame)
  def document_path = organisation_project_document_path(organisation, project, document, frame: 'content')

  # The note page itself answers a plain GET with a redirect into the knowledge
  # lane; its content frame is the read that renders the note.
  def note_read_path = note_path(frame: 'content', frame_id: 'knowledge_display_frame')

  shared_examples 'a member locked out of the archived project' do
    it 'reads the project while it is active (the pages exist)' do
      [ticket, note, document]
      sign_in user
      expect([ok?(ticket_path), ok?(note_read_path), ok?(document_path)]).to eq([true, true, true])
    end

    context 'once it is archived' do
      before do
        [ticket, note, document]
        archive!
        sign_in user
      end

      it 'opens no ticket, note or document by direct link' do
        expect([ok?(ticket_path), ok?(note_read_path), ok?(document_path)]).to eq([false, false, false])
      end

      it 'saves no ticket and no note' do
        patch ticket_path, params: { ticket: { title: 'Changed' } }
        patch note_path, params: { note: { title: 'Changed' } }

        expect(ticket.reload.title).to eq('Original title')
        expect(note.reload.title).to eq('Original note')
      end

      it 'lists the project in no access question' do
        policy = ProjectPolicy.new(user, project.reload)
        service = AccessCheck::ProjectAccessService

        expect(ProjectPermission.access_areas.map { |area| policy.area_access?(area, :read) }.uniq).to eq([false])
        expect(service.new(user, project).can?(:read, :tickets)).to be(false)
        expect(service.new(user, project).access_level(:tickets)).to eq('no_access')
        expect(service.can_access_project?(user, project)).to be(false)
        expect(service.accessible_projects(user, organisation)).not_to include(project)
        expect(service.accessible_projects(user, organisation, area: :notes)).not_to include(project)
        expect(service.accessible_project_ids(user, organisation, area: :documents)).not_to include(project.id)
        expect(service.users_with_access(project)).not_to include(user)
        expect(ProjectPolicy::Scope.new(user, Project).resolve).not_to include(project)
      end
    end
  end

  context 'with a direct grant on the project' do
    let(:user) { member.tap { |m| grant_everything(m) } }

    it_behaves_like 'a member locked out of the archived project'
  end

  context 'with a role right on every project' do
    let(:user) { member_in(global_role) }

    it_behaves_like 'a member locked out of the archived project'
  end

  describe 'an account admin' do
    before do
      [ticket, note]
      archive!
      sign_in admin
    end

    it 'keeps reading and writing' do
      expect([ok?(ticket_path), ok?(note_read_path)]).to eq([true, true])

      patch ticket_path, params: { ticket: { title: 'Changed by admin' } }
      expect(ticket.reload.title).to eq('Changed by admin')
      ids = ActsAsTenant.with_tenant(organisation) do
        AccessCheck::ProjectAccessService.accessible_project_ids(admin, organisation)
      end
      expect(ids).to include(project.id)
    end
  end

  describe 'booked time' do
    let(:user) { member.tap { |m| grant_everything(m) } }
    let!(:own_booking) { create(:time_session, project: project, creator: user, occurred_on: Time.current) }
    let!(:foreign_booking) { create(:time_session, project: project, creator: colleague, occurred_on: Time.current) }

    before do
      create(:time_session_permission, user: user, project: project, can_view_all: true, can_create_own: true,
                                       can_edit_own: true, can_delete_own: true, can_edit_all: true)
      archive!
    end

    it 'keeps the own hours readable and hides everybody else' do
      scope = TimeSessions::ViewingScope.call(user: user, project: project.reload)
      org_scope = TimeSessions::ViewingScope.for_organisation(user: user, organisation: organisation)

      expect(scope.tier).to eq(:own)
      expect(org_scope.tier_for(project.id)).to eq(:own)
      expect(org_scope.apply(TimeSession.all)).to contain_exactly(own_booking)
      expect(TimeSessionPolicy.new(user, own_booking).show?).to be(true)
      expect(TimeSessionPolicy.new(user, foreign_booking).show?).to be(false)
      expect(ProjectPolicy.new(user, project).area_access?(:time_sessions, :read)).to be(true)
    end

    it 'books, edits and deletes nothing' do
      expect(ProjectPolicy.new(user, project).area_access?(:time_sessions, :write)).to be(false)
      expect(TimeSessionPolicy.new(user, TimeSession.new(project: project, creator: user)).create?).to be(false)
      expect(TimeSessionPolicy.new(user, own_booking).update?).to be(false)
      expect(TimeSessionPolicy.new(user, own_booking).destroy?).to be(false)
      expect(TimeSessionPolicy.new(user, foreign_booking).update?).to be(false)

      sign_in user
      expect do
        post organisation_project_time_sessions_path(organisation, project),
             params: { time_session: { duration_string: '0:30', occurred_on: Date.current.to_s, description: 'x' } }
      end.not_to(change { ActsAsTenant.with_tenant(organisation) { TimeSession.count } })
    end
  end

  describe 'documentation sets' do
    let(:user) { member.tap { |m| grant_everything(m) } }
    let!(:set) { create(:documentation_set, project: project, organisation: organisation) }

    it 'drops the set of an archived project from the reader scope' do
      expect(DocumentationSetPolicy::Scope.new(user, DocumentationSet).resolve).to include(set)
      archive!
      expect(DocumentationSetPolicy::Scope.new(user, DocumentationSet).resolve).not_to include(set)
    end
  end
end
