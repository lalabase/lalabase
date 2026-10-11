# frozen_string_literal: true

require 'rails_helper'

# What this file protects
# -----------------------
# P4d is the half that makes P4a's trigger self-sustaining. Every example here guards a
# way the watcher could look like it works while quietly doing the wrong thing:
#
#   * flipping an org whose configuration never moved (a flip nobody asked for),
#   * missing the org whose space row failed to be created (E2.1 reason 1 — the one org
#     that needs help is the one the original SQL sketch could not see),
#   * re-driving a build against an exhausted quota (E2.2 — the retry loop E6 forbids),
#   * re-driving a RETIRED target forever (a build repairs nothing there),
#   * letting one broken org stop the sweep before it reaches the rest.
#
# The Factory is stubbed WITH the space: argument on both sides on purpose. A blanket
# `receive(:embedding_space_for)` would answer both questions with one value, and then
# "configured != active" could never be false — the whole predicate would go untested.
RSpec.describe Embeddings::SwitchWatcherJob do
  let(:organisation) { create(:organisation) }
  let(:old_triple) do
    { embedding_provider: 'openai', embedding_model: 'old-model', embedding_dims: 1536 }
  end
  let(:new_triple) do
    { embedding_provider: 'openai', embedding_model: 'new-model', embedding_dims: 1536 }
  end
  let(:target_space) do
    create(:embedding_space, organisation: organisation, embedding_model: 'new-model')
  end
  let(:flipped) { Actors::BaseActor::Result.new(success: true) }

  before do
    ActsAsTenant.current_tenant = organisation
    # Never let an example reach a real credential resolution: the watcher's own
    # decisions are what is under test here, not the factory's.
    allow(Lalabase::Llm::Gate).to receive(:exhausted?).and_return(false)
  end

  after { ActsAsTenant.current_tenant = nil }

  # The two lanes as the factory reports them. `configured` is what the org WOULD write
  # into, `active` what search reads from today.
  def lanes(configured:, active:, org: organisation)
    allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
      .with(org, space: :configured).and_return(configured)
    allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
      .with(org, space: :active).and_return(active)
  end

  def flip_returns(code)
    result = Actors::BaseActor::Result.new(success: false, errors: ['missing Fragment=3'], code: code)
    allow(Actors::FlipEmbeddingModel).to receive(:call).and_return(result)
  end

  describe 'candidate selection' do
    # The org whose lanes agree is not mid-switch. Asserting on EnsureSpace rather than
    # on the flip: the watcher must not even reach for the target space, because doing
    # so would write a row (and refresh credentials) for an org with nothing to do.
    it 'leaves an organisation alone whose configuration has not moved' do
      lanes(configured: old_triple, active: old_triple)
      expect(Embeddings::EnsureSpace).not_to receive(:call)

      described_class.perform_now
    end

    # The prefilter is `ai_enabled = true` and nothing else (E2.1): deliberately
    # over-inclusive, but an AI-off org is never a candidate — the switch cannot
    # complete for one, and every path below would fail on the factory's gate.
    it 'never looks at an organisation that has not opted in to AI' do
      organisation.update!(ai_enabled: false)
      expect(Lalabase::Llm::Factory).not_to receive(:embedding_space_for)

      described_class.perform_now
    end

    # E2.1, reason 1 — the finding that overturned the original plan sketch. Since P4a an
    # org can have a moved lane and NO embedding_spaces row, because EnsureSpace ran after
    # the commit and failed there. A watcher keyed on existing space rows would skip
    # exactly the org that is stuck. EnsureSpace is find-or-create, so calling it here IS
    # the repair.
    it 'creates the missing space row for an org whose lane moved without one' do
      lanes(configured: new_triple, active: old_triple)
      allow(Lalabase::Llm::Factory).to receive(:embedding_credentials_for).and_return({})
      allow(Actors::FlipEmbeddingModel).to receive(:call).and_return(flipped)

      expect { described_class.perform_now }
        .to change { EmbeddingSpace.where(organisation_id: organisation.id, **new_triple).count }
        .from(0).to(1)
    end
  end

  describe 'when the target space is complete' do
    before do
      lanes(configured: new_triple, active: old_triple)
      allow(Embeddings::EnsureSpace).to receive(:call).and_return(target_space)
    end

    it 'flips the organisation onto it' do
      allow(Actors::FlipEmbeddingModel).to receive(:call).and_return(flipped)

      described_class.perform_now

      expect(Actors::FlipEmbeddingModel).to have_received(:call)
        .with(organisation: organisation, target_space: target_space, current_user: nil)
    end

    # Not a style point. Asking for completeness here and flipping if it holds would run
    # the four anti-join scans TWICE per candidate (the actor validates regardless), and
    # would open a gap in which content created between check and flip lands outside the
    # target space.
    it 'asks the actor rather than judging completeness itself' do
      allow(Actors::FlipEmbeddingModel).to receive(:call).and_return(flipped)
      expect(Embeddings::OrganisationReindexer).not_to receive(:missing_in_space)

      described_class.perform_now
    end
  end

  describe 'when the target space is incomplete' do
    before do
      lanes(configured: new_triple, active: old_triple)
      allow(Embeddings::EnsureSpace).to receive(:call).and_return(target_space)
      flip_returns(:incomplete_target)
    end

    it 're-drives the build' do
      expect(Embeddings::ReindexOrganisationJob).to receive(:perform_later).with(organisation)

      described_class.perform_now
    end

    # E2.2. Without this the watcher starts the same job every 15 minutes, it fails at
    # the same gate, and the same line is logged — the retry loop E6 rules out in favour
    # of a PAUSED state. Resumption needs no trigger of its own: the next tick simply
    # stops skipping once the budget rolls.
    it 'skips silently while the AI quota is exhausted' do
      allow(Lalabase::Llm::Gate).to receive(:exhausted?)
        .with(organisation, 'openai', kind: :embedding).and_return(true)
      expect(Embeddings::ReindexOrganisationJob).not_to receive(:perform_later)

      described_class.perform_now
    end

    # The quota question is asked about the EMBEDDING lane. Asking with the default
    # kind: :chat would resolve a different billing credential — an org that pays for
    # chat out of quota but embeds via BYOK would be paused for a budget its reindex
    # does not draw on.
    it 'asks the quota gate about the embedding lane, not chat' do
      allow(Embeddings::ReindexOrganisationJob).to receive(:perform_later)

      described_class.perform_now

      expect(Lalabase::Llm::Gate).to have_received(:exhausted?)
        .with(organisation, 'openai', kind: :embedding)
    end
  end

  # A retired space HAS a row for every record and is only missing `indexed`; the repair
  # is reactivation, not a build. Reading "not complete" off a count of one's own and
  # re-enqueueing would re-embed a full corpus every 15 minutes and never change the
  # outcome. The actor already tells the two states apart — this proves the watcher
  # respects the distinction instead of flattening it.
  it 'does not re-drive a build for a merely RETIRED target' do
    lanes(configured: new_triple, active: old_triple)
    allow(Embeddings::EnsureSpace).to receive(:call).and_return(target_space)
    flip_returns(:retired_target)
    expect(Embeddings::ReindexOrganisationJob).not_to receive(:perform_later)

    described_class.perform_now
  end

  # One org with an unresolvable lane must not cost the fleet its sweep. TWO failing orgs
  # rather than one failing plus one healthy, because find_each iterates in primary-key
  # order and the ids are UUIDs: with a mixed pair the example would only catch a rescue
  # placed one level too high when the broken org happened to sort first. Two failures
  # must produce two log lines whichever order they come in — a rescue around the sweep
  # produces exactly one.
  it 'carries on to the next organisation when one raises a provider error' do
    second = create(:organisation)
    [organisation, second].each do |org|
      allow(Lalabase::Llm::Factory).to receive(:embedding_space_for)
        .with(org, space: :configured).and_raise(Lalabase::Llm::AiDisabledError, 'no credential')
    end
    allow(Rails.logger).to receive(:warn)

    expect { described_class.perform_now }.not_to raise_error

    expect(Rails.logger).to have_received(:warn).with(/#{organisation.id}/)
    expect(Rails.logger).to have_received(:warn).with(/#{second.id}/)
  end

  # Review finding 1. The rescue above used to name Provider::Error only, which covers
  # exactly what switch_pending? throws — and nothing that EnsureSpace throws. That call
  # WRITES a row, so it raises RecordInvalid or RecordNotUnique, the latter precisely when
  # it races the EnsureSpace inside Actors::SelectAiPackage on the same triple.
  #
  # The consequence was worse than one lost org: find_each iterates in stable primary-key
  # order and ApplicationJob declares no retry_on, so the same org aborted the sweep at
  # the same position every 15 minutes and everything behind it was never reached again —
  # silently, forever. Two failing orgs again, so the example cannot pass on iteration
  # order alone.
  it 'carries on when an organisation fails OUTSIDE the provider error family' do
    second = create(:organisation)
    [organisation, second].each do |org|
      lanes(configured: new_triple, active: old_triple, org: org)
    end
    allow(Embeddings::EnsureSpace).to receive(:call)
      .and_raise(ActiveRecord::RecordNotUnique, 'duplicate key value violates unique constraint')
    allow(Rails.logger).to receive(:error)

    expect { described_class.perform_now }.not_to raise_error

    # error rather than warn: a write colliding here is a bug, not a misconfigured org.
    expect(Rails.logger).to have_received(:error).with(/#{organisation.id}.*RecordNotUnique/)
    expect(Rails.logger).to have_received(:error).with(/#{second.id}.*RecordNotUnique/)
  end

  it 'is registered as a recurring task in every non-development environment' do
    config = YAML.load_file(Rails.root.join('config/recurring.yml'))
    %w[production staging].each do |env|
      expect(config.dig(env, 'embedding_switch_watcher', 'class')).to eq('Embeddings::SwitchWatcherJob')
    end
  end
end
