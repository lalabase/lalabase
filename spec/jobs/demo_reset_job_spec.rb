# frozen_string_literal: true

require 'rails_helper'

# Scheduled on every production instance; resets only the demo.
RSpec.describe DemoResetJob, :ci_guard do
  let(:demo_on) { true }

  around do |example|
    flag_was = ENV.fetch(Lalabase::Demo::ENV_FLAG, nil)
    ENV[Lalabase::Demo::ENV_FLAG] = demo_on ? Lalabase::Demo::ENABLED_VALUE : nil
    example.run
  ensure
    ENV[Lalabase::Demo::ENV_FLAG] = flag_was
  end

  before do
    allow(Lalabase::Demo::Reset).to receive(:call)
      .and_return(instance_double(Lalabase::Demo::World, organisation: build_stubbed(:organisation)))
  end

  it 'resets a marked demo' do
    SystemSetting.set(Lalabase::Demo::MARKER_KEY, true)
    described_class.perform_now
    expect(Lalabase::Demo::Reset).to have_received(:call)
  end

  it 'does nothing on a demo that was never set up' do
    described_class.perform_now
    expect(Lalabase::Demo::Reset).not_to have_received(:call)
  end

  context 'without the flag' do
    let(:demo_on) { false }

    it 'does nothing, marker or not' do
      SystemSetting.set(Lalabase::Demo::MARKER_KEY, true)
      described_class.perform_now
      expect(Lalabase::Demo::Reset).not_to have_received(:call)
    end
  end
end
