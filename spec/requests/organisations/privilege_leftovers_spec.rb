# frozen_string_literal: true

require 'rails_helper'

# Smaller boundaries inside an organisation, each with a control that goes
# through: the file proxy reads a comment's attachment only for someone who may
# read the comment, a smart folder share never hands out more than the sharer
# has, and a bulk group assignment finds the group through the policy.
RSpec.describe 'Organisation privilege boundaries (leftovers)', type: :request do
  let(:organisation) { create(:organisation) }
  let(:standard_role) { create(:role, organisation: organisation, title: "Member #{SecureRandom.hex(4)}") }
  let(:project) { create(:project, organisation: organisation) }

  def member(**project_access)
    create(:user).tap do |user|
      create(:membership, user: user, organisation: organisation, role: standard_role, active: true)
      create(:project_permission, user: user, project: project, **project_access) if project_access.any?
    end
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'file proxy for a comment attachment' do
    let(:reader) { member(tickets_access: 'read_only') }
    let(:ticket) { create(:ticket, project: project, organisation: organisation) }

    def document_on(post)
      create(:post_document, post: post, organisation: organisation)
    end

    it 'serves the attachment of a public comment' do
      document = document_on(create(:post, ticket: ticket, organisation: organisation))
      sign_in reader

      get organisation_file_download_path(organisation, kind: 'post_document', id: document.id)

      expect(response).to have_http_status(:ok)
    end

    it 'hides the attachment of a private comment addressed to someone else' do
      addressee = member(tickets_access: 'read_only')
      private_post = create(:post, ticket: ticket, organisation: organisation, is_private: true,
                                   visible_to_user: addressee)
      document = document_on(private_post)
      sign_in reader

      get organisation_file_download_path(organisation, kind: 'post_document', id: document.id)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'smart folder shares' do
    let(:owner) { member(tickets_access: 'read_write') }
    let(:sharer) { member(tickets_access: 'read_write') }
    let(:colleague) { member(tickets_access: 'read_only') }
    let(:third) { member(tickets_access: 'read_only') }
    let(:folder) do
      create(:smart_folder, user: owner, organisation: organisation, project: project, target_object_type: 'Ticket')
    end

    def share_of(user)
      ActsAsTenant.with_tenant(organisation) { folder.smart_folder_shares.find_by(user_id: user.id) }
    end

    def share(as:, with:, can_edit:)
      sign_in as
      post perform_share_organisation_smart_folder_path(organisation, folder),
           params: { share_user_ids: [with.id], share_can_edit: can_edit ? '1' : '0' }
    end

    it 'lets the owner hand out edit rights' do
      share(as: owner, with: colleague, can_edit: true)

      expect(share_of(colleague).can_edit).to be(true)
    end

    it 'does not let a sharer without edit rights hand them out' do
      create(:smart_folder_share, smart_folder: folder, user: sharer, can_share: true, can_edit: false)

      share(as: sharer, with: colleague, can_edit: true)

      expect(share_of(colleague)).to be_present
      expect(share_of(colleague).can_edit).to be(false)
    end

    it 'does not let a sharer remove somebody else\'s share' do
      create(:smart_folder_share, smart_folder: folder, user: sharer, can_share: true)
      create(:smart_folder_share, smart_folder: folder, user: colleague)
      sign_in sharer

      delete unshare_user_organisation_smart_folder_path(organisation, folder, colleague.id)

      expect(share_of(colleague)).to be_present
    end

    it 'lets a sharer remove their own share' do
      create(:smart_folder_share, smart_folder: folder, user: sharer, can_share: true)
      sign_in sharer

      delete unshare_user_organisation_smart_folder_path(organisation, folder, sharer.id)

      expect(share_of(sharer)).to be_nil
    end

    it 'lets the owner remove any share' do
      create(:smart_folder_share, smart_folder: folder, user: colleague)
      sign_in owner

      delete unshare_user_organisation_smart_folder_path(organisation, folder, colleague.id)

      expect(share_of(colleague)).to be_nil
    end
  end

  describe 'bulk group assignment of time sessions' do
    let(:booker) do
      member(tickets_access: 'read_write').tap do |user|
        create(:time_session_permission, user: user, project: project,
                                         can_view_own: true, can_create_own: true, can_edit_own: true)
      end
    end
    let!(:session) { create(:time_session, project: project, creator: booker, organisation: organisation) }

    def group_of(time_session)
      ActsAsTenant.with_tenant(organisation) { time_session.reload.time_session_group_id }
    end

    def assign(group)
      sign_in booker
      post bulk_assign_group_organisation_time_sessions_path(organisation),
           params: { time_session_ids: [session.id], existing_group_id: group.id }
    end

    # A non-admin sees a group through the sessions in it (TimeSessionGroupPolicy::Scope),
    # which is also what the form offers.
    it 'assigns to a group the booker may edit' do
      group = create(:time_session_group, organisation: organisation, creator: booker)
      create(:time_session, project: project, creator: booker, organisation: organisation, time_session_group: group)

      assign(group)

      expect(group_of(session)).to eq(group.id)
    end

    # Visible is not editable: seeing everyone's hours on the project shows the
    # group, but only its creator, finance or an admin may change it.
    it 'does not assign to a group the booker can see but not edit' do
      keeper = member
      group = create(:time_session_group, organisation: organisation, creator: keeper)
      create(:time_session, project: project, creator: keeper, organisation: organisation, time_session_group: group)
      ActsAsTenant.with_tenant(organisation) do
        TimeSessionPermission.find_by!(user: booker, project: project).update!(can_view_all: true)
      end

      assign(group)

      expect(group_of(session)).to be_nil
    end

    it 'does not assign to a group somebody else keeps' do
      group = create(:time_session_group, organisation: organisation, creator: member)

      assign(group)

      expect(group_of(session)).to be_nil
    end
  end
end
