# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260914120000_create_meeting_ticket_suggestion_runs')

RSpec.describe 'Suggestion run schema migration' do
  include_context 'assistant ticket suggestions'

  it 'adds the complete run schema without rewriting existing suggestions and cascades only private data' do
    existing = create(:meeting_ticket_suggestion, meeting: meeting)
    attributes = existing.attributes.except('meeting_ticket_suggestion_run_id')
    migration = CreateMeetingTicketSuggestionRuns.new
    ActiveRecord::Migration.suppress_messages do
      migration.migrate(:down)
      migration.migrate(:up)
    end
    expect(existing.reload.attributes.except('meeting_ticket_suggestion_run_id')).to eq(attributes)
    run = start_run
    expect(run.retried_at).to be_nil
    expect(run.sources['notes']).to include('sha256')
    expect(run.sources['notes']).not_to have_key('text')
    proposal = create(:meeting_ticket_suggestion, meeting: meeting, meeting_ticket_suggestion_run: run)
    run.chatpost.destroy!
    expect(MeetingTicketSuggestionRun.where(id: run.id)).not_to exist
    expect(proposal.reload.meeting_ticket_suggestion_run_id).to be_nil
    expect(proposal).to be_open
  end
end
