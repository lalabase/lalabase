# frozen_string_literal: true

require 'rails_helper'

# Meetings::TicketSuggestionJob — async entry point for the ticket-suggestion run.
# The one thing a job spec must prove here is tenant safety: it loads the tenanted
# meeting and runs the service inside the meeting's organisation even when dequeued
# with NO ambient tenant (Solid Queue). The service itself is stubbed (its own spec
# covers the run logic).
RSpec.describe Meetings::TicketSuggestionJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:meeting) do
    create(:meeting, organisation: organisation, project: project, creator: user, transcript: 'text')
  end

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'runs the service inside the meeting organisation without an ambient tenant' do
    meeting # create while the tenant is still set
    ActsAsTenant.current_tenant = nil

    tenant_seen = nil
    allow(Meetings::TicketSuggestionService).to receive(:call) { tenant_seen = ActsAsTenant.current_tenant }

    expect { described_class.new.perform(meeting_id: meeting.id) }.not_to raise_error
    expect(Meetings::TicketSuggestionService).to have_received(:call).with(meeting: meeting)
    expect(tenant_seen).to eq(organisation)
  end

  it 'discards quietly when the meeting no longer exists' do
    ActsAsTenant.current_tenant = nil
    expect(Rails.logger).to receive(:warn).with(/Meetings::TicketSuggestionJob discarded/)

    expect do
      described_class.perform_now(meeting_id: SecureRandom.uuid)
    end.not_to raise_error
  end

  it 'uses the default queue' do
    expect(described_class.new.queue_name).to eq('default')
  end
end
