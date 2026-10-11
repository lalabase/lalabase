# frozen_string_literal: true

require 'rails_helper'

# What: Embeddings::OrphanGcJob — the daily recurring wrapper around Embeddings::OrphanGc.
# Why:  It runs ONE GLOBAL sweep (organisation: nil → without_tenant); per-type
#       isolation lives INSIDE OrphanGc, so there is no per-org loop to starve. The
#       job is gated to DRY-RUN unless EMBEDDINGS_GC_ENFORCE=1 (review #354 #3), so
#       the first prod nights only log would-reclaim counts.
#
#       Since PR 6b there are TWO gates, and the point of these examples is that they
#       are INDEPENDENT. Orphan reclamation deletes rows whose owner is provably gone;
#       retention deletes intact vectors of a space the org still holds — the roll-back
#       net. Sharing one switch would mean an operator arming the harmless sweep also
#       arms the destructive one without being asked. Each gate is therefore asserted
#       BOTH ways: it arms its own sweep and leaves the other one dry.
RSpec.describe Embeddings::OrphanGcJob do
  before { allow(Embeddings::OrphanGc).to receive(:call) }

  def stub_env(**values)
    allow(ENV).to receive(:[]).and_call_original
    values.each { |name, value| allow(ENV).to receive(:[]).with(name.to_s).and_return(value) }
  end

  it 'runs ONE global GC with both sweeps dry by default (no per-org iteration)' do
    described_class.new.perform

    expect(Embeddings::OrphanGc).to have_received(:call)
      .with(dry_run: true, retention_dry_run: true).once
  end

  it 'arms orphan reclamation only when EMBEDDINGS_GC_ENFORCE=1, leaving retention dry' do
    stub_env(EMBEDDINGS_GC_ENFORCE: '1')

    described_class.new.perform

    expect(Embeddings::OrphanGc).to have_received(:call)
      .with(dry_run: false, retention_dry_run: true)
  end

  it 'arms retention only when EMBEDDINGS_RETENTION_ENFORCE=1, leaving orphans dry' do
    stub_env(EMBEDDINGS_RETENTION_ENFORCE: '1')

    described_class.new.perform

    expect(Embeddings::OrphanGc).to have_received(:call)
      .with(dry_run: true, retention_dry_run: false)
  end

  it 'arms both when both switches are set' do
    stub_env(EMBEDDINGS_GC_ENFORCE: '1', EMBEDDINGS_RETENTION_ENFORCE: '1')

    described_class.new.perform

    expect(Embeddings::OrphanGc).to have_received(:call)
      .with(dry_run: false, retention_dry_run: false)
  end

  it 'stays dry-run for any enforce value other than exactly "1"' do
    stub_env(EMBEDDINGS_GC_ENFORCE: 'true', EMBEDDINGS_RETENTION_ENFORCE: 'yes')

    described_class.new.perform

    expect(Embeddings::OrphanGc).to have_received(:call)
      .with(dry_run: true, retention_dry_run: true)
  end
end
