# frozen_string_literal: true

require 'rails_helper'

# Meetings::AnalysisJob — async entry point for a meeting analysis. Proves tenant
# safety: it loads the tenanted analysis and runs the service inside the analysis's
# organisation even when dequeued with NO ambient tenant (Solid Queue). Service stubbed.
RSpec.describe Meetings::AnalysisJob, type: :job do
  let(:organisation) { create(:organisation) }
  let(:project) { create(:project, organisation: organisation) }
  let(:user) { create(:user, organisation: organisation) }
  let(:meeting) { create(:meeting, organisation: organisation, project: project, creator: user, transcript: 'text') }
  let(:analysis) { create(:meeting_analysis, meeting: meeting, creator: user, creation_flag: true) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'runs the analysis service inside the analysis organisation without an ambient tenant' do
    analysis # create while the tenant is still set
    ActsAsTenant.current_tenant = nil

    tenant_seen = nil
    allow(Meetings::AnalysisService).to receive(:call) { tenant_seen = ActsAsTenant.current_tenant }

    expect { described_class.new.perform(analysis_id: analysis.id) }.not_to raise_error
    expect(Meetings::AnalysisService).to have_received(:call).with(analysis: analysis)
    expect(tenant_seen).to eq(organisation)
  end

  it 'discards quietly when the analysis no longer exists' do
    ActsAsTenant.current_tenant = nil
    expect(Rails.logger).to receive(:warn).with(/Meetings::AnalysisJob discarded/)

    expect do
      described_class.perform_now(analysis_id: SecureRandom.uuid)
    end.not_to raise_error
  end

  it 'uses the default queue' do
    expect(described_class.new.queue_name).to eq('default')
  end
end
