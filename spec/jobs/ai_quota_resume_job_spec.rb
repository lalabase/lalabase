# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AiQuotaResumeJob do
  it 'runs the activation backfill for an AI-enabled org' do
    org = create(:organisation)
    expect(Embeddings::ActivationBackfill).to receive(:call).with(org)
    described_class.new.perform(org)
  end

  it 'does nothing for an AI-disabled org (nothing to resume)' do
    org = create(:organisation, :ai_disabled)
    expect(Embeddings::ActivationBackfill).not_to receive(:call)
    described_class.new.perform(org)
  end

  it 'tolerates a nil organisation' do
    expect { described_class.new.perform(nil) }.not_to raise_error
  end
end
