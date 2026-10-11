# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Embeddings::ReindexOrganisationJob do
  let(:organisation) { create(:organisation) }

  # metered: true is asserted, not just presence of the call: this job IS the
  # customer-triggered path (P4a), and it is the ONE caller of the reindexer that
  # charges the org's quota. rake and DefaultModelMigrator pass false. A regression
  # that dropped the flag here would silently stop billing every package switch.
  it 'delegates to OrganisationReindexer as a METERED run' do
    # Entry point is the class-level .call since the PR-6a service-convention migration.
    allow(Embeddings::OrganisationReindexer).to receive(:call).and_return({})

    described_class.perform_now(organisation)

    expect(Embeddings::OrganisationReindexer).to have_received(:call)
      .with(organisation: organisation, metered: true)
  end

  # I1 (review of #422): the LIKELY failure of a customer-triggered switch. The
  # quota gate fires once, at the provider build — and with no retry_on anywhere in
  # this strand the job used to land in failed_executions without a single line
  # naming the organisation. The rare fault (an unresolvable lane) was logged
  # loudly by the actor; the probable one was mute.
  it 'pauses loudly instead of dying silently when the AI quota is exhausted' do
    allow(Embeddings::OrganisationReindexer).to receive(:call)
      .and_raise(Lalabase::Llm::QuotaExceededError, 'AI quota exhausted for organisation x')
    allow(Rails.logger).to receive(:warn)

    expect { described_class.perform_now(organisation) }.not_to raise_error

    expect(Rails.logger).to have_received(:warn).with(/#{organisation.id}.*switch paused/)
  end

  # Deliberately NOT swallowed: only the quota case is a "come back next month"
  # state. Everything else is a fault that belongs in failed_executions where it
  # is visible, rather than hidden behind a blanket rescue.
  it 'lets any other provider error fail the job' do
    allow(Embeddings::OrganisationReindexer).to receive(:call)
      .and_raise(Lalabase::Llm::AiDisabledError, 'nope')

    expect { described_class.perform_now(organisation) }.to raise_error(Lalabase::Llm::AiDisabledError)
  end

  it 'enqueues on the indexing queue' do
    expect(described_class.new.queue_name).to eq('indexing')
  end

  # GDPR AI opt-in (audit 2026-07-03): a bulk re-index embeds ALL org content,
  # so a non-opted-in org must skip before the reindexer is even built —
  # otherwise the factory gate would fail the job on every retry.
  it 'skips entirely when the org has not opted in to AI (no reindexer built)' do
    organisation.update!(ai_enabled: false)
    expect(Embeddings::OrganisationReindexer).not_to receive(:new)

    expect { described_class.perform_now(organisation) }.not_to raise_error
  end

  # P4d moved the "only one reindex per org at a time" rule OUT of its callers and into
  # this declaration — three triggers would otherwise have to obey it by hand (the
  # package actor, the switch watcher's re-drive, the P4b dialog). It is also §9's
  # second hard P4b precondition: two concurrent runs both find the same records missing
  # from the target space and both embed them, on a quota-metered path.
  describe 'concurrency control' do
    it 'allows one run at a time and DISCARDS the duplicate rather than queueing it' do
      expect(described_class.concurrency_limit).to eq(1)
      # :block would keep the duplicate and run it once the first finishes — a second
      # full corpus pass with nothing left to do. The watcher asks again anyway.
      expect(described_class.concurrency_on_conflict).to eq(:discard)
    end

    # The KEY is what makes this a per-org rule instead of a global one. Keyed on the
    # class alone (Solid Queue's default), one org's switch would block every other
    # org's — a fleet-wide serialisation nobody asked for.
    it 'keys the limit on the organisation, so two orgs still reindex independently' do
      other = create(:organisation)

      expect(described_class.new(organisation).concurrency_key)
        .to eq(described_class.new(organisation).concurrency_key)
      expect(described_class.new(organisation).concurrency_key)
        .not_to eq(described_class.new(other).concurrency_key)
    end
  end
end
