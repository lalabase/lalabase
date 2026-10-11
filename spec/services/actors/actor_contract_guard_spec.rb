# frozen_string_literal: true

require 'rails_helper'

# Guard: the Actors::* command-object contract (see CLAUDE.md "Actor-Pattern").
#
# Every actor under app/services/actors/ (except BaseActor) must:
#   1. inherit from Actors::BaseActor,
#   2. implement #perform (Tier-1 template) OR be a documented Tier-2 actor that
#      owns #call (tier_2_actors),
#   3. never set Current.user itself — that boundary lives in
#      BaseActor#with_actor_context (set + restore),
#   4. never enqueue a job with a raw perform_later — only via
#      BaseActor#enqueue_after_commit, so jobs fire after the real commit
#      (correct under PostUpdateService's outer transaction),
#   5. never inline the failure-mapping rescue chain — it lives once in
#      BaseActor#with_error_mapping (Tier-1 template + Tier-2 #call route
#      through it), or the tiers drift apart.
#
# A new actor that violates any of these turns this spec red. The three
# source-pattern checks (3 + 4 + 5) are extracted into predicates and unit-tested
# against synthetic input below, so a bypass (e.g. Current.user ||= ...) cannot
# silently slip through a too-narrow regex.
RSpec.describe 'Actor contract guard' do
  # Tier-2 actors own #call because their flow does not fit the #perform
  # template (SaveTicket: assignee/document sync outside the txn; MoveTicket:
  # RecordNotUnique retry; AcceptTicketSuggestion: atomic 3A claim + nested
  # SaveTicket composition in one transaction; CreateAiPost: LLM round-trip
  # must not hang in a txn; GenerateGroupCustomerDescriptions: LLM round-trip +
  # sync/async fork must not sit in a txn; CreateSignup: the language and the
  # tenant-free scope wrap the whole run, and the follow-ups that must not undo
  # the signup run after its commit). They still reuse the shared
  # BaseActor helpers.
  let(:tier_2_actors) do
    %w[Actors::SaveTicket Actors::AcceptTicketSuggestion Actors::CreateAiPost
       Actors::GenerateGroupCustomerDescriptions Actors::CreateSignup]
  end

  def actor_files
    Dir[Rails.root.join('app/services/actors/*.rb')]
      .reject { |f| File.basename(f) == 'base_actor.rb' }
      .sort
  end

  def actor_classes
    actor_files.map { |f| "Actors::#{File.basename(f, '.rb').camelize}".constantize }
  end

  # --- Source-pattern detectors (unit-tested in "detection logic" below) ------

  # True when the source reassigns Current.user itself (=, ||=, &&=), but not
  # for a comparison (==) or a plain read.
  def assigns_current_user?(source)
    source.match?(/Current\.user\s*(?:\|\||&&)?=(?!=)/)
  end

  # True when a raw perform_later survives once enqueue_after_commit blocks are
  # stripped out. Over-strict on purpose (errs toward flagging).
  def raw_perform_later?(source)
    without_wrapped = source.gsub(/enqueue_after_commit\s*(?:do|\{).*?(?:end|\})/m, '')
    without_wrapped.include?('perform_later')
  end

  # True when a concrete actor inlines the failure-mapping rescue chain instead
  # of routing through BaseActor#with_error_mapping. That policy
  # (RecordInvalid / ActorError / StaleObjectError / StandardError -> failure)
  # must live in exactly ONE place; otherwise the tiers drift (they already had:
  # SaveTicket lacked StaleObjectError, MoveTicket lacked RecordInvalid +
  # ActorError). A domain-specific retry such as
  # `rescue ActiveRecord::RecordNotUnique` is intentionally NOT matched.
  def inlines_error_mapping?(source)
    source.match?(/rescue\s+(?:ActiveRecord::RecordInvalid|Actors::ActorError|ActorError|ActiveRecord::StaleObjectError|StandardError)\b/)
  end

  # --- Contract checks against the real actors --------------------------------

  it 'discovers the expected actor files' do
    # Sanity check so an empty glob cannot make the guard vacuously pass.
    expect(actor_files.length).to be >= 9
  end

  it 'every actor inherits from Actors::BaseActor' do
    offenders = actor_classes.reject { |k| k < Actors::BaseActor }

    expect(offenders).to be_empty, "Not inheriting from Actors::BaseActor: #{offenders.join(', ')}"
  end

  it 'every actor implements #perform or is a documented Tier-2 actor' do
    allowlist = tier_2_actors
    offenders = actor_classes.reject do |klass|
      klass.instance_method(:perform).owner == klass || allowlist.include?(klass.name)
    end

    expect(offenders).to be_empty, <<~MSG
      These actors neither implement #perform nor are in the Tier-2 allowlist:
        #{offenders.join(', ')}
      Implement #perform (Tier-1), or add the actor to tier_2_actors if it owns #call.
    MSG
  end

  it 'no actor sets Current.user itself (boundary belongs to with_actor_context)' do
    offenders = actor_files.select { |f| assigns_current_user?(File.read(f)) }
    names = offenders.map { |f| File.basename(f) }

    expect(names).to be_empty, <<~MSG
      These actors assign Current.user directly: #{names.join(', ')}
      Remove it — BaseActor#with_actor_context sets and restores Current.user.
    MSG
  end

  it 'no actor enqueues a raw perform_later outside enqueue_after_commit' do
    offenders = actor_files.select { |f| raw_perform_later?(File.read(f)) }
    names = offenders.map { |f| File.basename(f) }

    expect(names).to be_empty, <<~MSG
      These actors call perform_later outside enqueue_after_commit: #{names.join(', ')}
      Wrap the enqueue: enqueue_after_commit { SomeJob.perform_later(...) }.
    MSG
  end

  it 'no actor inlines the failure-mapping rescue chain (it belongs to with_error_mapping)' do
    offenders = actor_files.select { |f| inlines_error_mapping?(File.read(f)) }
    names = offenders.map { |f| File.basename(f) }

    expect(names).to be_empty, <<~MSG
      These actors inline the failure-mapping rescue chain: #{names.join(', ')}
      Remove it — wrap the body in with_error_mapping { ... } so the policy
      (RecordInvalid / ActorError / StaleObjectError / StandardError) lives once
      in BaseActor. Domain retries (rescue ActiveRecord::RecordNotUnique) are fine.
    MSG
  end

  it 'the Tier-2 allowlist only lists existing actors that own #call' do
    tier_2_actors.each do |name|
      klass = name.constantize
      owner = klass.instance_method(:perform).owner

      expect(klass < Actors::BaseActor).to be(true), "#{name} is not an Actors::BaseActor subclass"
      expect(owner).to eq(Actors::BaseActor), "#{name} implements #perform — it is Tier-1, remove it"
    end
  end

  # --- Detection logic: pin the boundaries of the source-pattern checks --------

  describe 'Current.user detection (#assigns_current_user?)' do
    it 'flags plain, ||=, &&= and no-space assignments' do
      expect(assigns_current_user?('Current.user = @current_user')).to be(true)
      expect(assigns_current_user?('Current.user ||= @current_user')).to be(true)
      expect(assigns_current_user?('Current.user &&= @current_user')).to be(true)
      expect(assigns_current_user?('Current.user=@current_user')).to be(true)
    end

    it 'ignores comparisons and reads (no false positives)' do
      expect(assigns_current_user?('return if Current.user == actor')).to be(false)
      expect(assigns_current_user?('previous = Current.user')).to be(false)
      expect(assigns_current_user?('Current.user.preferences.update!(x: 1)')).to be(false)
    end
  end

  describe 'raw perform_later detection (#raw_perform_later?)' do
    it 'ignores perform_later wrapped in enqueue_after_commit (do and brace forms)' do
      expect(raw_perform_later?("enqueue_after_commit do\n  Job.perform_later(x)\nend")).to be(false)
      expect(raw_perform_later?('enqueue_after_commit { Job.perform_later(x) }')).to be(false)
    end

    it 'flags a perform_later outside the helper, even next to a wrapped one' do
      source = "enqueue_after_commit { A.perform_later }\nB.perform_later(y)"
      expect(raw_perform_later?(source)).to be(true)
    end

    it 'does not confuse purge_later with perform_later' do
      expect(raw_perform_later?('Blob.where(id: ids).find_each(&:purge_later)')).to be(false)
    end
  end

  describe 'inline error-mapping detection (#inlines_error_mapping?)' do
    it 'flags each mapping-chain rescue an actor must not own itself' do
      expect(inlines_error_mapping?('rescue ActiveRecord::RecordInvalid => e')).to be(true)
      expect(inlines_error_mapping?('rescue Actors::ActorError => e')).to be(true)
      expect(inlines_error_mapping?('rescue ActorError => e')).to be(true)
      expect(inlines_error_mapping?('rescue ActiveRecord::StaleObjectError')).to be(true)
      expect(inlines_error_mapping?('rescue StandardError => e')).to be(true)
    end

    it 'ignores a domain-specific RecordNotUnique retry (the Tier-2 reason itself)' do
      expect(inlines_error_mapping?('rescue ActiveRecord::RecordNotUnique => e')).to be(false)
    end

    it 'does not flag a call to with_error_mapping or unrelated text' do
      expect(inlines_error_mapping?('with_error_mapping do')).to be(false)
      expect(inlines_error_mapping?('# maps StandardError to a failure')).to be(false)
    end
  end
end
