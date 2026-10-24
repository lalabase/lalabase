# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::MoveMeeting, type: :service do
  let(:organisation) { create(:organisation) }
  let(:admin_role) { create(:admin_role, organisation: organisation) }
  let(:standard_role) { create(:role, organisation: organisation, title: 'Standard User') }
  let(:admin) { create(:user) }
  let(:member) { create(:user) }
  let(:source_project) { create(:project, organisation: organisation) }
  let(:target_project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: admin, organisation: organisation, role: admin_role)
    create(:membership, user: member, organisation: organisation, role: standard_role)
  end

  # After the before block: the tenant has to be set first.
  let!(:meeting) { create(:meeting, project: source_project, organisation: organisation, creator: admin) }

  def move(current_user: admin, target: target_project)
    described_class.call(meeting: meeting, target_project: target, current_user: current_user)
  end

  describe '#call' do
    it 'moves the meeting into the target project' do
      result = move

      expect(result).to be_success
      expect(meeting.reload.project_id).to eq(target_project.id)
    end

    it 'moves the booked time with it, billed sessions included' do
      open_session = create(:time_session, project: source_project, organisation: organisation, meeting: meeting)
      billed_session = create(:time_session, project: source_project, organisation: organisation, meeting: meeting,
                                             billed: true, billed_at: 1.day.ago)
      other_session = create(:time_session, project: source_project, organisation: organisation)

      move

      expect(open_session.reload.project_id).to eq(target_project.id)
      expect(billed_session.reload.project_id).to eq(target_project.id)
      expect(other_session.reload.project_id).to eq(source_project.id)
    end

    it "moves the meeting's notifications so the inbox rule reads the new project" do
      notification = create(:notification, recipient: member, organisation: organisation,
                                           notifiable: meeting, project: source_project)

      move

      expect(notification.reload.project_id).to eq(target_project.id)
    end

    it 'dismisses the open AI ticket suggestions and leaves the others alone' do
      open_suggestion = create(:meeting_ticket_suggestion, meeting: meeting)
      dismissed_suggestion = create(:meeting_ticket_suggestion, :dismissed, meeting: meeting)

      move

      expect(open_suggestion.reload).to be_dismissed
      expect(dismissed_suggestion.reload).to be_dismissed
    end

    it 'records the move on both projects' do
      move

      moved_out = Activity.find_by(trackable: source_project, key: 'project.meeting_moved_out')
      moved_in = Activity.find_by(trackable: target_project, key: 'project.meeting_moved_in')
      expect(moved_out.secondary).to eq(meeting)
      expect(moved_out.parameters).to include('meeting_title' => meeting.title, 'to_project_id' => target_project.id)
      expect(moved_in.secondary).to eq(meeting)
      expect(moved_in.parameters).to include('meeting_title' => meeting.title, 'from_project_id' => source_project.id)
    end

    it 'keeps a saved analysis publishable when its only source is this meeting' do
      own = create(:meeting_analysis, meeting: meeting, organisation: organisation, creator: admin,
                                      source_context: { 'provenance' => [
                                        { 'type' => 'meeting', 'id' => meeting.id, 'project_id' => source_project.id }
                                      ] })
      scoped = create(:meeting_analysis, meeting: meeting, organisation: organisation, creator: admin,
                                         source_context: { 'provenance' => [
                                           { 'type' => 'meeting', 'id' => meeting.id, 'project_id' => source_project.id },
                                           { 'type' => 'project', 'id' => source_project.id }
                                         ] })

      move

      expect(own.reload).to be_sources_publishable
      expect(own.source_context['provenance'].first['project_id']).to eq(target_project.id)
      # The chat was narrowed to the source project: that stays a foreign source.
      expect(scoped.reload).not_to be_sources_publishable
    end

    it 'carries the displayed citations of this meeting and its analyses along' do
      analysis = create(:meeting_analysis, meeting: meeting, organisation: organisation, creator: admin,
                                           source_context: { 'citations' => [
                                             { 'type' => 'meeting', 'id' => meeting.id, 'project_id' => source_project.id },
                                             { 'type' => 'ticket', 'id' => SecureRandom.uuid, 'project_id' => source_project.id }
                                           ], 'provenance' => [] })
      analysis.source_context['citations'] << { 'type' => 'meeting_analysis', 'id' => analysis.id,
                                                'project_id' => source_project.id }
      analysis.save!

      move

      projects = analysis.reload.source_context['citations'].to_h { |citation| [citation['type'], citation['project_id']] }
      expect(projects).to eq('meeting' => target_project.id, 'meeting_analysis' => target_project.id,
                             'ticket' => source_project.id)
    end

    describe '#preflight' do
      it 'names the booked time, the billed part and the open suggestions' do
        create(:time_session, project: source_project, organisation: organisation, meeting: meeting)
        create(:time_session, project: source_project, organisation: organisation, meeting: meeting,
                              billed: true, billed_at: 1.day.ago)
        create(:meeting_ticket_suggestion, meeting: meeting)

        impact = described_class.new(meeting: meeting, target_project: target_project, current_user: admin).preflight

        expect(impact).to include(time_sessions_count: 2, billed_time_sessions_count: 1,
                                  open_suggestions_count: 1, ticket_links_count: 0, bound_analyses_count: 0)
      end
    end

    context 'when refused' do
      def expect_refusal(result, code)
        expect(result).not_to be_success
        expect(result.code).to eq(code)
        expect(meeting.reload.project_id).to eq(source_project.id)
      end

      it 'refuses a meeting with a linked ticket' do
        ticket = create(:ticket, project: source_project, organisation: organisation, creator: admin)
        Reference.create!(source: meeting, target: ticket, target_title_snapshot: ticket.title)

        expect_refusal(move, :has_ticket_links)
      end

      it 'refuses a meeting whose linked ticket is gone (the link survives as a tombstone)' do
        ticket = create(:ticket, project: source_project, organisation: organisation, creator: admin)
        Reference.create!(source: meeting, target: ticket, target_title_snapshot: ticket.title)
        ticket.destroy!

        expect_refusal(move, :has_ticket_links)
      end

      it 'refuses while an AI ticket suggestion run is active' do
        MeetingTicketSuggestionRun.create!(meeting: meeting, organisation: organisation, project_id: source_project.id,
                                           job_id: SecureRandom.uuid, meeting_title: meeting.title,
                                           project_title: source_project.name, status: :running)

        expect_refusal(move, :suggestion_run_active)
      end

      it 'moves when the active run is stale (a lost job must not block the move forever)' do
        run = MeetingTicketSuggestionRun.create!(meeting: meeting, organisation: organisation,
                                                 project_id: source_project.id, job_id: SecureRandom.uuid,
                                                 meeting_title: meeting.title, project_title: source_project.name,
                                                 status: :queued)
        run.update_columns(updated_at: (Meeting::SUGGESTIONS_STALE_AFTER + 1.minute).ago)

        expect(move).to be_success
      end

      # Two moves of the same meeting race: the second passed its checks against
      # the project the meeting was in, then waited for the row lock while the
      # first moved it. It must not move the meeting out of a project it was
      # never checked against.
      it 'refuses when the meeting moved while the move waited for its lock' do
        elsewhere = create(:project, organisation: organisation)
        allow(meeting).to receive(:lock!).and_wrap_original do |original, *args|
          Meeting.where(id: meeting.id).update_all(project_id: elsewhere.id)
          original.call(*args)
        end

        result = move

        expect(result).not_to be_success
        expect(result.code).to eq(:moved_meanwhile)
        # The stand-in for the other move ran inside this transaction and rolled
        # back with the refusal; what counts is that this move wrote nothing.
        expect(meeting.reload.project_id).not_to eq(target_project.id)
      end

      # A chat narrowed to the source project is a source of its own: the
      # analysis may not be public in the target, so the move does not decide
      # that silently. Unpublish it first.
      it 'refuses while a published analysis cites the source project' do
        create(:meeting_analysis, meeting: meeting, organisation: organisation, creator: admin, is_private: false,
                                  source_context: { 'provenance' => [
                                    { 'type' => 'meeting', 'id' => meeting.id, 'project_id' => source_project.id },
                                    { 'type' => 'project', 'id' => source_project.id }
                                  ] })

        expect_refusal(move, :published_analyses_bound)
      end

      it 'moves when such an analysis is private' do
        create(:meeting_analysis, meeting: meeting, organisation: organisation, creator: admin,
                                  source_context: { 'provenance' => [{ 'type' => 'project', 'id' => source_project.id }] })

        expect(move).to be_success
      end

      it 'refuses the project the meeting is already in' do
        expect_refusal(move(target: source_project), :same_project)
      end

      it 'refuses a target project the user may not write meetings in' do
        create(:project_permission, user: member, project: source_project, meetings_access: 'read_write')
        create(:project_permission, user: member, project: target_project, meetings_access: 'read_only')

        expect_refusal(move(current_user: member), :forbidden_target)
      end

      it 'refuses an archived target project' do
        target_project.update!(archived_at: Time.current)

        expect_refusal(move, :forbidden_target)
      end
    end
  end
end
