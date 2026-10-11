# frozen_string_literal: true

require 'rails_helper'

# What this file protects
# -----------------------
# The flip is the one moment where a staged switch can go wrong irreversibly-looking:
# pointing serving at a space that does not hold the whole corpus makes the missing
# part unreachable, and unreachable content here does not raise — it returns zero hits.
#
# So the refusal is tested TWICE, deliberately:
#   * a genuinely incomplete target must be refused, and
#   * a target that a COUNT COMPARISON would call complete (because orphaned sidecar
#     rows pad the total) must ALSO be refused.
# The second example is the one with teeth: swap the anti-join for "target rows >=
# records" and the first still passes while the second fails. Without it the weaker
# implementation would look fully tested (M3, series plan §5.3 step 3).
RSpec.describe Actors::FlipEmbeddingModel do
  let(:organisation) { create(:organisation) }
  let(:user)         { create(:user) }
  let(:target)       { create(:embedding_space, organisation: organisation, embedding_model: 'target-model') }

  before { ActsAsTenant.current_tenant = organisation }
  after  { ActsAsTenant.current_tenant = nil }

  def flip(space: target)
    described_class.call(organisation: organisation, target_space: space, current_user: user)
  end

  # A record that IS readable in the target space.
  def covered_fragment
    create(:fragment, :for_ticket, organisation: organisation).tap do |fragment|
      create(:content_embedding, organisation: organisation, embeddable: fragment,
                                 embedding_provider: 'openai', embedding_model: 'target-model',
                                 embedding_dims: 1536, indexed: true)
    end
  end

  describe 'the flip itself' do
    it 'moves the pointer to the target space' do
      covered_fragment

      expect(flip).to be_success
      expect(organisation.reload.active_embedding_space_id).to eq(target.id)
    end

    it 'is a SINGLE update statement (the atomicity the staged switch rests on)' do
      covered_fragment
      writes = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        writes << payload[:sql] if payload[:sql].match?(/\AUPDATE "organisations"/)
      end

      flip
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(writes.size).to eq(1)
      expect(writes.first).to include('active_embedding_space_id')
    end

    it 'succeeds on an empty corpus (nothing to be missing)' do
      expect(flip).to be_success
    end

    # [T1, review 2026-08-01] The property `update_column` is chosen for, spelled out as
    # a test instead of only as a comment: an organisation carrying an UNRELATED
    # validation error must stay flippable. Otherwise the one action that moves an org
    # OUT of a broken vector space would be blocked by something that has nothing to do
    # with embeddings.
    #
    # The 'SINGLE update statement' example above does not cover this — `update!` emits
    # exactly one UPDATE too. Only an invalid record tells the two apart.
    it 'flips an organisation that currently fails an unrelated validation' do
      covered_fragment
      organisation.update_column(:name, nil) # invalid, and unrelated to embeddings
      expect(organisation.reload).not_to be_valid

      expect(flip).to be_success
      expect(organisation.reload.active_embedding_space_id).to eq(target.id)
    end

    it 'refuses a space belonging to another organisation' do
      other = create(:organisation, name: 'Other', subdomain: 'other-flip')
      foreign = ActsAsTenant.with_tenant(other) { create(:embedding_space, organisation: other) }

      result = flip(space: foreign)

      expect(result).not_to be_success
      expect(result.code).to eq(:foreign_space)
      expect(organisation.reload.active_embedding_space_id).to be_nil
    end

    it 'refuses to flip onto the space that is already active' do
      organisation.update!(active_embedding_space_id: target.id)

      result = flip

      expect(result).not_to be_success
      expect(result.code).to eq(:already_active)
    end
  end

  describe 'completeness validation (M3)' do
    it 'refuses while a source record has no readable row in the target space' do
      create(:fragment, :for_ticket, organisation: organisation) # no target-space row

      result = flip

      expect(result).not_to be_success
      expect(result.code).to eq(:incomplete_target)
      expect(result.errors.first).to include('Fragment=1')
      expect(organisation.reload.active_embedding_space_id).to be_nil
    end

    # THE anti-join test. Two fragments, ONE of them covered; plus two ORPHANED rows in
    # the target space (their records are gone). A count comparison sees 3 target rows
    # for 2 fragments and concludes "complete" — the anti-join still finds the one
    # fragment nobody can read.
    it 'is not fooled by orphaned rows that make the COUNT look complete' do
      covered_fragment
      uncovered = create(:fragment, :for_ticket, organisation: organisation)
      # Uniform per-iteration setup queries, not a production N+1 — the fixture loop is
      # what this example needs, so Prosopite is paused around it (house pattern,
      # ticket_spec.rb:295).
      Prosopite.pause do
        2.times do
          orphan_source = create(:fragment, :for_ticket, organisation: organisation)
          create(:content_embedding, organisation: organisation, embeddable: orphan_source,
                                     embedding_provider: 'openai', embedding_model: 'target-model',
                                     embedding_dims: 1536, indexed: true)
          orphan_source.delete # callback-free: the sidecar row stays behind as an orphan
        end
      end

      # Precondition of the example: a naive count really would pass.
      target_rows = ContentEmbedding.where(organisation_id: organisation.id, **target.triple).count
      expect(target_rows).to be >= Fragment.where(organisation_id: organisation.id).count

      result = flip

      expect(result).not_to be_success
      expect(result.code).to eq(:incomplete_target)
      expect(uncovered.reload).to be_present
      expect(organisation.reload.active_embedding_space_id).to be_nil
    end

    # `indexed` is part of "readable" — a retired row is one the reader cannot see, so
    # it must not satisfy completeness either.
    #
    # [F2, review 2026-08-01] But it is a DIFFERENT state from "half built", and the two
    # need opposite repairs. Telling the operator to run `build_target` here would send
    # them to build the CONFIGURED space — during a roll-back, the very one they are
    # leaving. Hence its own code.
    it 'reports a fully-populated but retired target space as retired, not incomplete' do
      fragment = create(:fragment, :for_ticket, organisation: organisation)
      create(:content_embedding, organisation: organisation, embeddable: fragment,
                                 embedding_provider: 'openai', embedding_model: 'target-model',
                                 embedding_dims: 1536, indexed: false)

      result = flip

      expect(result).not_to be_success
      expect(result.code).to eq(:retired_target)
      expect(organisation.reload.active_embedding_space_id).to be_nil
    end

    # Negative control for the example above: rows genuinely ABSENT (not merely
    # de-indexed) must keep the incomplete_target code, or the distinction collapses
    # into "everything is retired".
    it 'still reports a genuinely half-built space as incomplete' do
      covered_fragment
      create(:fragment, :for_ticket, organisation: organisation) # no target row at all

      result = flip

      expect(result).not_to be_success
      expect(result.code).to eq(:incomplete_target)
    end

    # A space that is retired AND missing rows is incomplete, not retired: building is
    # the first thing needed, and reactivation alone would not make it complete.
    it 'prefers incomplete over retired when rows are missing as well' do
      retired = create(:fragment, :for_ticket, organisation: organisation)
      create(:content_embedding, organisation: organisation, embeddable: retired,
                                 embedding_provider: 'openai', embedding_model: 'target-model',
                                 embedding_dims: 1536, indexed: false)
      create(:fragment, :for_ticket, organisation: organisation) # no row at all

      expect(flip.code).to eq(:incomplete_target)
    end
  end

  # PR 6b. Which space is being displaced was read from the in-memory organisation
  # until now (review finding R5) — a time-of-check/time-of-use gap: a stale or
  # concurrently-updated instance names the WRONG predecessor, so the space that
  # actually stopped serving is neither retired nor dated. It stays in the ANN indexes,
  # and the retention GC, which orders by exactly that date, then keeps the wrong one.
  #
  # NOT PROVEN HERE: the concurrency itself. These examples pin the MECHANISM — the
  # decision comes from a fresh read rather than from the instance handed in. A genuine
  # two-connection race test is not something this suite establishes.
  describe 'which space is displaced (read fresh, under lock)' do
    let(:previous) { create(:embedding_space, organisation: organisation, embedding_model: 'previous-model') }

    around do |example|
      original = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
      ActiveJob::Base.queue_adapter = original
    end

    it 'dates the displaced space and clears the date on the incoming one' do
      # The target served before and was retired then — this is a switch BACK to it.
      target.update_column(:retired_at, 5.days.ago)
      organisation.update_column(:active_embedding_space_id, previous.id)
      covered_fragment

      expect(flip).to be_success
      expect(previous.reload.retired_at).to be_present
      expect(target.reload.retired_at).to be_nil
    end

    it 'dates nothing on an org first flip (no space was displaced)' do
      covered_fragment

      expect(flip).to be_success
      expect(target.reload.retired_at).to be_nil
      expect(EmbeddingSpace.where.not(retired_at: nil)).to be_empty
    end

    # THE R5 example: the caller hands in an organisation whose pointer is out of date,
    # and the flip must displace what is ACTUALLY serving, not what that instance
    # believes is.
    it 'displaces the space the DATABASE names, not the one the instance remembers' do
      other = create(:embedding_space, organisation: organisation, embedding_model: 'other-model')
      organisation.update_column(:active_embedding_space_id, previous.id)
      stale_instance = Organisation.find(organisation.id) # remembers `previous`
      # Someone else flips in between — `other` is what serves now.
      Organisation.find(organisation.id).update_column(:active_embedding_space_id, other.id)
      covered_fragment

      result = described_class.call(organisation: stale_instance, target_space: target,
                                    current_user: user)

      expect(result).to be_success
      expect(other.reload.retired_at).to be_present
      expect(previous.reload.retired_at).to be_nil
      expect(Embeddings::RetireSpaceJob).to have_been_enqueued.with(organisation.id, other.id)
    end

    # The same staleness the other way round: the instance believes another space is
    # active while the target already is. That flip must still be refused, and the
    # refusal has to come from the fresh read as well.
    it 'refuses when the database already has the target active, however stale the instance' do
      organisation.update_column(:active_embedding_space_id, previous.id)
      stale_instance = Organisation.find(organisation.id)
      Organisation.find(organisation.id).update_column(:active_embedding_space_id, target.id)
      covered_fragment

      result = described_class.call(organisation: stale_instance, target_space: target,
                                    current_user: user)

      expect(result).not_to be_success
      expect(result.code).to eq(:already_active)
    end

    # The rake `embeddings:flip` path (review C1): the task sets NO ambient tenant and
    # require_tenant is on. stamp_retirement used to build its EmbeddingSpace relation
    # outside any tenant lift, so the relation evaluated acts_as_tenant's default scope
    # tenant-less and raised NoTenantSet — invisible to this suite, because every other
    # example runs under the ambient tenant the before-hook sets. This example IS that
    # missing condition: red before the with_tenant fix, green after.
    it 'flips and stamps without an ambient tenant (the rake embeddings:flip path)' do
      target.update_column(:retired_at, 5.days.ago)
      organisation.update_column(:active_embedding_space_id, previous.id)
      covered_fragment
      ActsAsTenant.current_tenant = nil

      result = described_class.call(organisation: organisation, target_space: target,
                                    current_user: user)

      expect(result).to be_success
      expect(previous.reload.retired_at).to be_present
      expect(target.reload.retired_at).to be_nil
    end

    # The organisation vanished between the anti-joins and the locked read. The refusal
    # must name THAT — reusing :foreign_space here told the operator the space belongs
    # to a different organisation, about an organisation that no longer exists.
    it 'refuses with :organisation_gone when the organisation row vanished before the locked read' do
      covered_fragment
      allow(Organisation).to receive(:lock).and_return(Organisation.none)

      result = described_class.call(organisation: organisation, target_space: target,
                                    current_user: user)

      expect(result).not_to be_success
      expect(result.code).to eq(:organisation_gone)
    end
  end

  describe 'retirement of the previous space' do
    # The ActiveJob matchers need the :test adapter (house pattern,
    # spec/models/user_data_export_spec.rb:138); restored afterwards so the adapter
    # choice does not leak into other files.
    around do |example|
      original = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      example.run
      ActiveJob::Base.queue_adapter = original
    end

    it 'enqueues retirement of the space that was active before' do
      previous = create(:embedding_space, organisation: organisation, embedding_dims: 1024)
      organisation.update!(active_embedding_space_id: previous.id)
      covered_fragment

      expect { flip }
        .to have_enqueued_job(Embeddings::RetireSpaceJob).with(organisation.id, previous.id)
    end

    it 'enqueues nothing on an org first flip (there is no previous space)' do
      covered_fragment

      expect { flip }.not_to have_enqueued_job(Embeddings::RetireSpaceJob)
    end

    # enqueue_after_commit: a refused flip must not schedule retirement of a space that
    # is still serving.
    it 'enqueues nothing when the flip is refused' do
      create(:fragment, :for_ticket, organisation: organisation)
      previous = create(:embedding_space, organisation: organisation, embedding_dims: 1024)
      organisation.update!(active_embedding_space_id: previous.id)

      expect { flip }.not_to have_enqueued_job(Embeddings::RetireSpaceJob)
    end
  end
end
