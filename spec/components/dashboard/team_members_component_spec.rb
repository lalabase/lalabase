# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Dashboard::TeamMembersComponent, type: :component do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:member_role) { create(:role, organisation: organisation, title: 'member') }
  let(:tickets_reader_role) do
    role = create(:role, organisation: organisation, title: 'tickets_reader')
    create(:project_read_permission, role: role, area: 'tickets')
    role
  end

  def member_in(role)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role)
    user
  end

  # Viewer is an account admin, so the candidate roster is the whole org.
  let(:viewer) { member_in(admin_role) }
  let(:component) { described_class.new(project: project, user: viewer) }

  def member_users
    component.send(:members).map(&:user)
  end

  describe '#members — effective roster, not just explicit grants' do
    it 'includes an account admin who has NO explicit ProjectPermission (the reported bug)' do
      admin = member_in(admin_role)
      expect(member_users).to include(admin)
    end

    it 'includes a global-role member who has no explicit grant' do
      role_member = member_in(tickets_reader_role)
      expect(member_users).to include(role_member)
    end

    it 'includes an explicit (direct) grant member' do
      direct = member_in(member_role)
      create(:project_permission, user: direct, project: project, tickets_access: 'read_write')
      expect(member_users).to include(direct)
    end

    it 'excludes a member with no access from any source' do
      no_access = member_in(member_role)
      expect(member_users).not_to include(no_access)
    end
  end

  describe 'rendered provenance badge' do
    before do
      policy = instance_double(ProjectPolicy)
      allow(Current).to receive(:project_policy).with(viewer, project).and_return(policy)
      allow(policy).to receive(:area_access?).with(:members, :write).and_return(false)
    end

    it 'shows the role title for a global-role member' do
      member_in(tickets_reader_role)
      result = render_inline(component)
      expect(result.text).to include('tickets_reader')
    end

    it 'shows no provenance badge for an explicit (direct) grant' do
      direct = member_in(member_role)
      create(:project_permission, user: direct, project: project, tickets_access: 'read_write')
      result = render_inline(component)
      # The direct member's name renders, but no "via Rolle"/"via role" provenance text.
      expect(result.text).to include(direct.full_name.presence || direct.email)
      expect(result.text).not_to match(/via Rolle|via role/)
    end
  end

  # Since S3 this widget draws each member through Neo::Users::NameComponent in circle
  # mode, and that component asks avatar.attached? per member — one query each unless the
  # feeding scope preloads the attachment and its blob (the hazard its own comment names,
  # name_component.rb:27). The loop is fed by AccessCheck::ProjectTeamMembers, so the
  # preload has to live in THAT query; the widget cannot add it after the fact.
  describe 'avatar preloading' do
    before do
      policy = instance_double(ProjectPolicy)
      allow(Current).to receive(:project_policy).with(viewer, project).and_return(policy)
      allow(policy).to receive(:area_access?).with(:members, :write).and_return(false)
    end

    # Seeded in a method, not a before block: attaching an avatar reads the blob and
    # pre-warms the variant, which is a loop over records rather than a request N+1, so
    # Prosopite has to be paused around it. A before block runs AFTER the global
    # Prosopite.scan and would pause too late.
    #
    # Three DISTINCT members with an avatar each: with a single one there is nothing for
    # a per-member query to repeat over, and both examples would pass without the preload.
    def seed_members_with_avatars
      Prosopite.pause
      3.times do
        member = member_in(member_role)
        create(:project_permission, user: member, project: project, tickets_access: 'read_write')
        member.avatar.attach(io: Rails.root.join('spec/fixtures/files/test_avatar.png').open,
                             filename: 'avatar.png', content_type: 'image/png')
        member.save!
      end
    ensure
      Prosopite.resume
    end

    def attachment_queries_during
      seen = []
      subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        seen << payload[:sql] if payload[:sql]&.include?('active_storage_attachments')
      end
      yield
      seen
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    # Counted, not sampled: with the preload the render issues the batched attachment load
    # and nothing per member. Take the preload out of ProjectTeamMembers#candidate_users
    # and this is one lookup per member of the project, on every project dashboard.
    it 'pays no per-member attachment query while rendering the circles' do
      seed_members_with_avatars

      queries = attachment_queries_during { render_inline(component) }

      expect(queries.size).to be <= 2
    end

    it 'hands the resolved members users whose attachment and blob are already loaded' do
      seed_members_with_avatars

      users = component.send(:members).map(&:user)
      expect(users.size).to eq(4) # the three seeded members plus the account-admin viewer

      # loaded? is asked BEFORE anything reads the association: touching it first would
      # load it lazily and make this example true with the preload gone.
      expect(users.map { |user| user.association(:avatar_attachment).loaded? }).to all(be(true))

      attachments = users.filter_map(&:avatar_attachment)
      expect(attachments.size).to eq(3)
      expect(attachments.map { |att| att.association(:blob).loaded? }).to all(be(true))
    end
  end
end
