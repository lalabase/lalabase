# frozen_string_literal: true

require 'rails_helper'

# Contract specs for the hardened Actors::BaseActor template.
#
# What: the behaviour every actor inherits — the class-level .call forwarder,
#   the #call template (transaction -> perform -> enqueue -> success), the
#   #perform/#record interface enforcement, error mapping (RecordInvalid /
#   ActorError / unexpected), the Current.user set+restore boundary, the
#   after-commit enqueue wiring, and the tenant-scoped #find_or_build helper.
# Why: Phase 1 of the actor refactor moves duplicated per-actor logic into the
#   base class. These specs pin that seam so a regression in the shared template
#   is caught here instead of leaking into every concrete actor.
#
# The tests use throwaway anonymous subclasses so the base contract is verified
# in isolation from any concrete domain actor.
#
# Note on after-commit tests: the suite runs with transactional fixtures, so a
# real ActiveRecord.after_all_transactions_commit block would be deferred to the
# wrapping test transaction (which never commits). We therefore assert the
# *wiring* (enqueue goes through after_all_transactions_commit, the job lives in
# the registered block) via a spy. The real rollback semantics belong to Rails
# and are exercised end-to-end at the integration level in a later phase.
RSpec.describe Actors::BaseActor, type: :service do
  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  before { stub_const('BaseActorSpecJob', Class.new(ApplicationJob) { def perform(*); end }) }

  # Builds and returns a concrete actor instance. Pass the write as a block;
  # omit it to leave BaseActor#perform (NotImplementedError) in place.
  def actor_with(record: :the_record, current_user: nil, enqueue_jobs: nil, &perform_impl)
    klass = Class.new(described_class) do
      define_method(:record) { record }
      define_method(:perform, &perform_impl) if perform_impl
      define_method(:enqueue_jobs, &enqueue_jobs) if enqueue_jobs
    end
    instance = klass.new
    instance.instance_variable_set(:@current_user, current_user)
    instance
  end

  # A record stand-in that satisfies ActiveRecord::RecordInvalid.new(record).
  # `errors` is a real method (not a stub) so verify_partial_doubles is happy.
  let(:invalid_record) do
    klass = Class.new do
      attr_reader :errors

      def initialize(errors)
        @errors = errors
      end

      def self.i18n_scope = :activerecord
    end
    klass.new(double('errors', full_messages: ['Title is blank']))
  end

  describe Actors::ActorError do
    it 'wraps a single message into an array and uses it as the exception message' do
      err = described_class.new('boom')

      expect(err.messages).to eq(['boom'])
      expect(err.message).to eq('boom')
    end

    it 'keeps multiple messages and joins them with commas for #message' do
      err = described_class.new(%w[a b c])

      expect(err.messages).to eq(%w[a b c])
      expect(err.message).to eq('a, b, c')
    end

    it 'defaults #code to :domain_error' do
      expect(described_class.new('boom').code).to eq(:domain_error)
    end

    it 'carries an explicit machine-readable #code for callers (e.g. API -> HTTP status)' do
      expect(described_class.new('nope', code: :not_member).code).to eq(:not_member)
    end
  end

  describe '.call' do
    it 'forwards keyword args to .new and runs #call' do
      klass = Class.new(described_class) do
        def initialize(value:)
          super()
          @value = value
        end

        def perform = nil
        def record = @value
      end

      result = klass.call(value: 99)

      expect(result.success?).to be(true)
      expect(result.resource).to eq(99)
    end
  end

  describe 'interface enforcement' do
    it 'raises NotImplementedError when #perform is not implemented' do
      actor = Class.new(described_class) { def record = :r }.new
      expect { actor.call }.to raise_error(NotImplementedError, /perform/)
    end

    it 'raises NotImplementedError when #record is not implemented' do
      actor = Class.new(described_class) { def perform = nil }.new
      expect { actor.call }.to raise_error(NotImplementedError, /record/)
    end
  end

  describe 'error mapping' do
    it 'maps ActiveRecord::RecordInvalid to a failure with the record errors' do
      # Local (not the `invalid_record` let): the perform block runs with `self`
      # rebound to the actor, so a method/let lookup would not resolve there.
      error = ActiveRecord::RecordInvalid.new(invalid_record)
      actor = actor_with(record: :doc) { raise error }

      result = actor.call

      expect(result.success?).to be(false)
      expect(result.errors).to eq(['Title is blank'])
      # failure() resolves the resource via #record (safe_record).
      expect(result.resource).to eq(:doc)
    end

    it 'maps an ActorError with multiple messages to a failure' do
      actor = actor_with { raise Actors::ActorError, %w[boom bang] }

      expect(actor.call.errors).to eq(%w[boom bang])
    end

    it 'wraps a single ActorError message into an array' do
      actor = actor_with { raise Actors::ActorError, 'single' }

      expect(actor.call.errors).to eq(['single'])
    end

    it 're-raises unexpected errors in dev/test (raise_unexpected? is true here)' do
      actor = actor_with { raise 'kaboom' }

      expect(actor.send(:raise_unexpected?)).to be(true) # the test-env default
      expect { actor.call }.to raise_error(RuntimeError, 'kaboom')
    end

    it 'logs and returns a failure for unexpected errors when raise_unexpected? is false (prod-like)' do
      actor = actor_with { raise 'kaboom' }
      allow(actor).to receive(:raise_unexpected?).and_return(false)
      expect(Rails.logger).to receive(:error).with(/RuntimeError: kaboom/)

      result = actor.call

      expect(result.success?).to be(false)
      expect(result.errors).to eq(['kaboom'])
    end
  end

  # Result#code is the machine-readable failure kind. It lets callers branch on
  # the failure *type* (e.g. the API maps it to an HTTP status) instead of
  # sniffing error strings. Every rescue branch in the centralised
  # with_error_mapping must stamp the right code; this block pins that mapping.
  describe 'failure codes' do
    it 'stamps :ok on a successful result' do
      expect(actor_with { nil }.call.code).to eq(:ok)
    end

    it 'maps RecordInvalid to code :validation_failed' do
      error = ActiveRecord::RecordInvalid.new(invalid_record)
      expect(actor_with { raise error }.call.code).to eq(:validation_failed)
    end

    it 'maps StaleObjectError to code :stale_object' do
      result = actor_with { raise ActiveRecord::StaleObjectError }.call

      expect(result.code).to eq(:stale_object)
      expect(result.errors).to eq([I18n.t('services.actors.stale_object')])
    end

    it 'propagates the ActorError code onto the failure result' do
      actor = actor_with { raise Actors::ActorError.new('x', code: :not_member) }

      expect(actor.call.code).to eq(:not_member)
    end

    it 'defaults an ActorError without an explicit code to :domain_error' do
      expect(actor_with { raise Actors::ActorError, 'x' }.call.code).to eq(:domain_error)
    end

    it 'maps an unexpected error to code :internal_error (prod-like, no re-raise)' do
      actor = actor_with { raise 'kaboom' }
      allow(actor).to receive(:raise_unexpected?).and_return(false)
      allow(Rails.logger).to receive(:error)

      expect(actor.call.code).to eq(:internal_error)
    end

    it 'defaults a bare failure() call to code :error' do
      expect(actor_with { nil }.send(:failure, 'oops').code).to eq(:error)
    end
  end

  describe 'transaction boundary' do
    it 'runs #perform inside a database transaction (one level deeper than the caller)' do
      outer_depth = ActiveRecord::Base.connection.open_transactions
      inner_depth = nil
      actor = actor_with { inner_depth = ActiveRecord::Base.connection.open_transactions }

      actor.call

      expect(inner_depth).to eq(outer_depth + 1)
    end
  end

  describe 'failure resource safety' do
    it 'coerces a non-array error argument into an array' do
      actor = actor_with { nil }

      expect(actor.send(:failure, 'just a string').errors).to eq(['just a string'])
    end

    it 'swallows a StandardError raised by #record while building a failure' do
      klass = Class.new(described_class) do
        def perform = raise(Actors::ActorError, 'domain fail')
        def record = raise('record boom')
      end

      result = klass.new.call

      expect(result.success?).to be(false)
      expect(result.errors).to eq(['domain fail']) # the domain error, not the record error
      expect(result.resource).to be_nil            # safe_record swallowed the record error
    end
  end

  describe '#handle_unexpected_error' do
    let(:actor) { actor_with { nil } }

    it 're-raises the error when reraise: true' do
      expect { actor.send(:handle_unexpected_error, RuntimeError.new('x'), reraise: true) }
        .to raise_error(RuntimeError, 'x')
    end

    it 'returns a failure Result when reraise: false' do
      result = actor.send(:handle_unexpected_error, RuntimeError.new('y'), reraise: false)

      expect(result.success?).to be(false)
      expect(result.errors).to eq(['y'])
    end
  end

  describe 'Current.user boundary' do
    let(:previous_user) { double('previous user') }
    let(:actor_user) { double('actor user') }

    after { Current.user = nil }

    it 'sets Current.user during #perform and restores the previous value afterwards' do
      Current.user = previous_user
      seen = nil
      actor = actor_with(current_user: actor_user) { seen = Current.user }

      actor.call

      expect(seen).to eq(actor_user)            # set for the duration of the write
      expect(Current.user).to eq(previous_user) # restored, no leak
    end

    it 'restores nil when there was no previous user' do
      Current.user = nil
      actor = actor_with(current_user: actor_user) { nil }

      actor.call

      expect(Current.user).to be_nil
    end

    it 'does not overwrite Current.user when the actor carries no current_user' do
      Current.user = previous_user
      seen = nil
      actor = actor_with(current_user: nil) { seen = Current.user }

      actor.call

      expect(seen).to eq(previous_user) # the `&& current_user` guard skipped the set
      expect(Current.user).to eq(previous_user)
    end
  end

  describe '#find_or_build' do
    let(:actor) { actor_with { nil } }
    let(:relation) { double('tenant-scoped relation') }

    it 'returns the existing record when the id is found in the scoped relation' do
      existing = double('existing')
      allow(relation).to receive(:find_by).with(id: '1').and_return(existing)
      expect(relation).not_to receive(:build)

      expect(actor.send(:find_or_build, relation, '1')).to eq(existing)
    end

    it 'builds a new record when the id is blank, without a lookup' do
      built = double('built')
      expect(relation).not_to receive(:find_by)
      allow(relation).to receive(:build).with({ title: 'x' }).and_return(built)

      expect(actor.send(:find_or_build, relation, nil, { title: 'x' })).to eq(built)
    end

    it 'builds within the scoped relation when the id is not found (no cross-tenant leak)' do
      built = double('freshly built')
      allow(relation).to receive(:find_by).with(id: 'foreign').and_return(nil)
      # Also pins the empty-Hash default for build_attrs.
      expect(relation).to receive(:build).with({}).and_return(built)

      expect(actor.send(:find_or_build, relation, 'foreign')).to eq(built)
    end

    context 'with a distinct build_scope (find and build scoped differently)' do
      let(:find_scope) { double('find scope (org-wide)') }
      let(:build_scope) { double('build scope (project)') }

      it 'finds in find_scope and never touches build_scope when the id resolves' do
        existing = double('existing')
        allow(find_scope).to receive(:find_by).with(id: '7').and_return(existing)
        expect(build_scope).not_to receive(:build)

        result = actor.send(:find_or_build, find_scope, '7', {}, build_scope: build_scope)
        expect(result).to eq(existing)
      end

      it 'builds in build_scope (not find_scope) when the id is not found' do
        allow(find_scope).to receive(:find_by).with(id: 'missing').and_return(nil)
        built = double('built in project')
        # The build MUST happen on build_scope, never on find_scope — that is the
        # whole point of the separate scope (SaveTicket: org-find, project-build).
        expect(find_scope).not_to receive(:build)
        expect(build_scope).to receive(:build).with({ title: 'x' }).and_return(built)

        result = actor.send(:find_or_build, find_scope, 'missing', { title: 'x' }, build_scope: build_scope)
        expect(result).to eq(built)
      end

      it 'builds in build_scope when the id is blank, without any lookup' do
        expect(find_scope).not_to receive(:find_by)
        built = double('built')
        allow(build_scope).to receive(:build).with({}).and_return(built)

        result = actor.send(:find_or_build, find_scope, nil, build_scope: build_scope)
        expect(result).to eq(built)
      end
    end
  end

  describe '#raise_unexpected? (config-driven)' do
    let(:actor) { actor_with { nil } }

    it 'reads the decision from config.x.actors.reraise_unexpected' do
      original = Rails.application.config.x.actors.reraise_unexpected
      Rails.application.config.x.actors.reraise_unexpected = false
      expect(actor.send(:raise_unexpected?)).to be(false)

      Rails.application.config.x.actors.reraise_unexpected = true
      expect(actor.send(:raise_unexpected?)).to be(true)
    ensure
      Rails.application.config.x.actors.reraise_unexpected = original
    end

    it 'defaults to true in the test environment (re-raise, fail loudly)' do
      expect(actor.send(:raise_unexpected?)).to be(true)
    end
  end

  describe 'after-commit enqueue' do
    let(:enqueueing) do
      actor_with(enqueue_jobs: -> { enqueue_after_commit { BaseActorSpecJob.perform_later } }) { nil }
    end

    it 'registers the job through after_all_transactions_commit and enqueues it on commit' do
      expect(ActiveRecord).to receive(:after_all_transactions_commit).and_yield

      expect { enqueueing.call }.to have_enqueued_job(BaseActorSpecJob)
    end

    it 'does not enqueue while the commit has not happened (block only runs after commit)' do
      # Capture the block but never yield it -> simulates a not-yet-committed
      # (or rolled-back) outer transaction.
      allow(ActiveRecord).to receive(:after_all_transactions_commit)

      expect { enqueueing.call }.not_to have_enqueued_job(BaseActorSpecJob)
    end

    it 'does not enqueue when #perform fails (enqueue runs only after the write)' do
      klass = Class.new(described_class) do
        def perform = raise(Actors::ActorError, 'nope')
        def record = :r
        def enqueue_jobs = enqueue_after_commit { BaseActorSpecJob.perform_later }
      end
      allow(ActiveRecord).to receive(:after_all_transactions_commit).and_yield

      expect { klass.new.call }.not_to have_enqueued_job(BaseActorSpecJob)
    end
  end
end
