# frozen_string_literal: true

require 'rails_helper'

# `bin/rails lalabase:demo:setup`: the only writer of the reset's second latch, and
# only on an instance with nothing to lose.
RSpec.describe Lalabase::Demo::Setup, :ci_guard do
  let(:demo_on) { true }
  let(:world) { instance_double(Lalabase::Demo::World) }

  around do |example|
    flag_was = ENV.fetch(Lalabase::Demo::ENV_FLAG, nil)
    ENV[Lalabase::Demo::ENV_FLAG] = demo_on ? Lalabase::Demo::ENABLED_VALUE : nil
    example.run
  ensure
    ENV[Lalabase::Demo::ENV_FLAG] = flag_was
  end

  before { allow(Lalabase::Demo::Reset).to receive(:call).and_return(world) }

  it 'marks the instance, closes the registration and runs the first reset' do
    expect(described_class.call).to eq(world)

    expect(Lalabase::Demo).to be_marked
    expect(SystemSetting.allow_registration?).to be(false)
    expect(Lalabase::Demo::Reset).to have_received(:call)
  end

  it 'refuses on an instance with an organisation' do
    create(:organisation)

    expect { described_class.call }.to raise_error(described_class::Refused, /organisations/)
    expect(Lalabase::Demo).not_to be_marked
    expect(Lalabase::Demo::Reset).not_to have_received(:call)
  end

  it 'refuses a second time' do
    described_class.call

    expect { described_class.call }.to raise_error(described_class::Refused, /demo already/)
  end

  # The real reset, called the way the rake task calls it: no tenant, no stub.
  it 'leaves a world to sign in to' do
    allow(Lalabase::Demo::Reset).to receive(:call).and_call_original
    allow(Embeddings::ActivationBackfill).to receive(:call)

    world = Prosopite.pause { described_class.call }
    expect(world.signed_in.valid_password?(Lalabase::Demo::PASSWORD)).to be(true)
    expect(Lalabase::Demo).to be_resettable
  end

  context 'without the flag' do
    let(:demo_on) { false }

    it 'refuses and writes nothing' do
      expect { described_class.call }.to raise_error(described_class::Refused, /LALABASE_DEMO/)
      expect(Lalabase::Demo).not_to be_marked
    end
  end
end
