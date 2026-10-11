# frozen_string_literal: true

require 'rails_helper'

# Organisations::MeetingParticipantClaims — the org-level link/reject endpoints for
# the participant claim hint (Nachtrag). Load-bearing guarantees:
#  - a meetings-writer sees the hint on BOTH indexes and can link / reject;
#  - a meetings-reader sees no hint and is redirected out of both POSTs (the app's
#    redirect convention, not a literal 403);
#  - the actor's tamper guards hold end-to-end (foreign / inactive target links
#    nothing);
#  - reject is idempotent and makes the hint disappear.
RSpec.describe 'Organisations::MeetingParticipantClaims', type: :request do
  let(:organisation) { create(:organisation) }
  let(:project) { ActsAsTenant.with_tenant(organisation) { create(:project, organisation: organisation) } }

  def user_with_access(level, on: project)
    user = create(:user)
    ActsAsTenant.with_tenant(organisation) do
      role = create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation)
      create(:membership, user: user, organisation: organisation, role: role, active: true)
      create(:project_permission, user: user, project: on, meetings_access: level) unless level == :none
    end
    user
  end

  let(:writer) { user_with_access('read_write') }
  let(:reader) { user_with_access('read_only') }

  # An active, named org member (a claim candidate).
  def member_named(first, last, active: true)
    member = create(:user, first_name: first, last_name: last)
    ActsAsTenant.with_tenant(organisation) do
      create(:membership, user: member, organisation: organisation,
                          role: create(:role, title: "Role #{SecureRandom.hex(4)}", organisation: organisation), active: active)
    end
    member
  end

  # A meeting in `on` with a single external participant `name` (user_id nil).
  def external_meeting(name, on: project)
    ActsAsTenant.with_tenant(organisation) do
      meeting = create(:meeting, project: on, organisation: organisation, creator: writer)
      create(:meeting_participant, meeting: meeting, organisation: organisation, display_name: name)
      meeting
    end
  end

  def rejection_count
    ActsAsTenant.with_tenant(organisation) { MeetingParticipantClaimRejection.count }
  end

  def normalize(name)
    MeetingParticipant.normalize_name(name)
  end

  let(:link_path) { link_organisation_meeting_participant_claims_path(organisation) }
  let(:reject_path) { reject_organisation_meeting_participant_claims_path(organisation) }
  let(:heading) { I18n.t('views.organisations.meetings.claim.heading') }

  describe 'claim hint on the indexes' do
    let!(:member) { member_named('Karl', 'Krause') }
    let!(:meeting) { Prosopite.pause { external_meeting('Karl Krause') } }

    it 'shows the hint to a meetings-writer on the project index' do
      sign_in writer
      get organisation_project_meetings_path(organisation, project)
      expect(response.body).to include(heading)
      expect(response.body).to include('Karl Krause')
    end

    it 'shows the hint on the org-wide index' do
      sign_in writer
      get organisation_meetings_path(organisation)
      expect(response.body).to include(heading)
    end

    it 'shows the hint on a standalone (bookmarked) meeting show, not only the bare index' do
      # The standalone show renders the full :index; the lazy meeting_claim_matches
      # helper must surface the banner there too (regression: it did not when the
      # hint was set only in #index).
      sign_in writer
      get organisation_project_meeting_path(organisation, project, meeting)
      expect(response.body).to include(heading)
    end

    it 'hides the hint from a meetings-reader (no write access anywhere)' do
      sign_in reader
      get organisation_project_meetings_path(organisation, project)
      expect(response.body).not_to include(heading)
    end
  end

  describe 'POST link' do
    let!(:member) { member_named('Karl', 'Krause') }
    let!(:meeting) { external_meeting('Karl Krause') }

    it 'links the external participations and flashes a notice for a writer' do
      sign_in writer
      post link_path, params: { user_id: member.id, normalized_name: normalize('Karl Krause') }

      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to be_present
      linked = ActsAsTenant.with_tenant(organisation) { meeting.meeting_participants.first.user_id }
      expect(linked).to eq(member.id)
    end

    it 'denies a reader (redirect) and links nothing' do
      sign_in reader
      post link_path, params: { user_id: member.id, normalized_name: normalize('Karl Krause') }

      expect(response).to have_http_status(:redirect)
      linked = ActsAsTenant.with_tenant(organisation) { meeting.meeting_participants.first.user_id }
      expect(linked).to be_nil
    end

    it 'reports target_missing for a user that is not an org member and links nothing' do
      outsider = create(:user, first_name: 'Out', last_name: 'Sider')
      sign_in writer
      post link_path, params: { user_id: outsider.id, normalized_name: normalize('Karl Krause') }

      expect(response).to have_http_status(:see_other)
      expect(flash[:alert]).to be_present
      linked = ActsAsTenant.with_tenant(organisation) { meeting.meeting_participants.first.user_id }
      expect(linked).to be_nil
    end

    it 'reports failure for an INACTIVE member (actor tamper guard) and links nothing' do
      inactive = member_named('Karl', 'Krause', active: false)
      sign_in writer
      post link_path, params: { user_id: inactive.id, normalized_name: normalize('Karl Krause') }

      expect(flash[:alert]).to be_present
      linked = ActsAsTenant.with_tenant(organisation) { meeting.meeting_participants.first.user_id }
      expect(linked).to be_nil
    end
  end

  describe 'POST link — nothing new to link' do
    it 'shows a neutral notice (not a green "0 linked") when every match is already linked' do
      member = member_named('Karl', 'Krause')
      # The only "Karl Krause" external row sits in a meeting that already links the
      # member (under a different name) → the actor skips it → 0 linked but success.
      ActsAsTenant.with_tenant(organisation) do
        m = create(:meeting, project: project, organisation: organisation, creator: writer)
        create(:meeting_participant, meeting: m, organisation: organisation, display_name: 'Karl Krause')
        create(:meeting_participant, meeting: m, organisation: organisation, display_name: 'Karl', user: member)
      end

      sign_in writer
      post link_path, params: { user_id: member.id, normalized_name: normalize('Karl Krause') }

      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq(I18n.t('flash.meeting_participant_claims.nothing_to_link', name: 'Karl Krause'))
    end
  end

  describe 'POST reject' do
    let!(:member) { member_named('Karl', 'Krause') }

    before { Prosopite.pause { external_meeting('Karl Krause') } }

    it 'persists the rejection and the hint then disappears' do
      sign_in writer
      expect do
        post reject_path, params: { user_id: member.id, normalized_name: normalize('Karl Krause') }
      end.to change { rejection_count }.by(1)
      expect(response).to have_http_status(:see_other)

      get organisation_meetings_path(organisation)
      expect(response.body).not_to include(heading)
    end

    it 'is idempotent — a double reject neither errors nor duplicates' do
      sign_in writer
      2.times { post reject_path, params: { user_id: member.id, normalized_name: normalize('Karl Krause') } }

      expect(response).to have_http_status(:see_other)
      expect(rejection_count).to eq(1)
    end

    it 'denies a reader and records no rejection' do
      sign_in reader
      expect do
        post reject_path, params: { user_id: member.id, normalized_name: normalize('Karl Krause') }
      end.not_to(change { rejection_count })
      expect(response).to have_http_status(:redirect)
    end
  end

  describe 'authentication' do
    it 'redirects an unauthenticated link POST to login' do
      post link_path, params: { user_id: SecureRandom.uuid, normalized_name: 'x' }
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
