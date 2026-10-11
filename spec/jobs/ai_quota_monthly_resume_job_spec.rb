# frozen_string_literal: true

require 'rails_helper'

# S3 KI-Kontingent (decision 5A/D13): the monthly reset catch-up enqueues one
# resume per pending org, oldest first, and skips AI-off orgs.
RSpec.describe AiQuotaMonthlyResumeJob do
  it 'enqueues a resume for each pending, AI-enabled org and skips AI-off ones' do
    enabled = create(:organisation)
    disabled = create(:organisation, :ai_disabled)
    allow(Embeddings::PendingBacklog).to receive(:organisation_ids_oldest_first)
      .and_return([enabled.id, disabled.id])

    expect(AiQuotaResumeJob).to receive(:perform_later).with(enabled)
    expect(AiQuotaResumeJob).not_to receive(:perform_later).with(disabled)

    described_class.new.perform
  end

  it 'is registered as a recurring task in every non-development environment' do
    config = YAML.load_file(Rails.root.join('config/recurring.yml'))
    %w[production staging].each do |env|
      expect(config.dig(env, 'ai_quota_monthly_resume', 'class')).to eq('AiQuotaMonthlyResumeJob')
    end
  end
end
