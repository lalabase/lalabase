# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: the rake task `embeddings:check_alignment` — the GATE around
#       Embeddings::SpaceAlignment.
# Why:  the task's entire value is its EXIT CODE. Ops and CI run it before and after
#       a model switch and read nothing but the status; the verdict logic itself is
#       covered by space_alignment_spec. What NO other spec covers is `abort` vs
#       `puts` — a refactor could disarm the gate to a purely informational printout
#       without a single example turning red. These examples pin the exit code per
#       verdict, deliberately asserting on the exit and on marker words only, not on
#       the full wording (which is free to change).
# Pattern: first rake spec in this repo. Load the tasks once, `reenable` before each
#       invoke (a Rake task runs at most once per process), capture $stdout/$stderr,
#       and read the SystemExit that `abort` raises — its message IS the abort text
#       and its status is 1.
RSpec.describe 'embeddings:check_alignment (and the verdict renderer it shares with :status)' do
  before(:all) do
    # Idempotent: loading twice would append the task bodies a second time and run
    # every action twice.
    Rails.application.load_tasks unless Rake::Task.task_defined?('embeddings:check_alignment')
  end

  # The task iterates organisations itself and runs without an ambient tenant, like
  # the real rake process does.
  before { ActsAsTenant.current_tenant = nil }

  let(:active_space) { EmbeddingSidecarHelpers::DEFAULT_EMBEDDING_SPACE }
  let(:legacy_space) do
    { embedding_provider: 'openai', embedding_model: 'text-embedding-ada-002', embedding_dims: 1536 }
  end

  # @return [CodeSymbol] the embedded record, so an example can delete it
  def embedded_symbol(organisation, space)
    ActsAsTenant.with_tenant(organisation) do
      project = create(:project, organisation: organisation)
      repository = create(:project_repository, organisation: organisation, project: project)
      symbol = create(:code_symbol, organisation: organisation, project_repository: repository)
      create(:content_embedding, organisation: organisation, embeddable: symbol,
                                 embedding: Array.new(space[:embedding_dims], 0.001), **space)
      symbol
    end
  end

  # @return [Array(String, SystemExit, nil)] captured stdout + the SystemExit `abort`
  #   raised (nil on a clean run)
  def run_task(organisation_id, name: 'embeddings:check_alignment')
    task = Rake::Task[name]
    task.reenable
    stdout = StringIO.new
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = stdout
    $stderr = StringIO.new # abort() also writes its message here; keep the suite quiet
    begin
      task.invoke(organisation_id)
      [stdout.string, nil]
    rescue SystemExit => e
      [stdout.string, e]
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end
  end

  context 'with a resolvable read space (active system credential)' do
    before { create(:ai_credential, :active, provider: 'openai') }

    it 'exits ZERO when every record has a readable row' do
      organisation = create(:organisation)
      embedded_symbol(organisation, active_space)

      output, exit_error = run_task(organisation.id)

      expect(exit_error).to be_nil
      expect(output).to include('Verdict: ALIGNED')
    end

    it 'ABORTS with status 1 when a record is stranded and AI is enabled' do
      organisation = create(:organisation)
      embedded_symbol(organisation, legacy_space)

      output, exit_error = run_task(organisation.id)

      expect(exit_error).to be_a(SystemExit)
      expect(exit_error.status).to eq(1)
      expect(exit_error.message).to include('BLOCKED')
      expect(output).to include('Verdict: MISALIGNED')
    end

    # Same finding, different org state: the printed repair (reindex) raises
    # AiDisabledError while AI is off, so blocking here would leave the gate red on
    # something nobody can fix from this side.
    it 'exits ZERO on the SAME finding while AI is switched off, and says why' do
      organisation = create(:organisation, :ai_disabled)
      embedded_symbol(organisation, legacy_space)

      output, exit_error = run_task(organisation.id)

      expect(exit_error).to be_nil
      expect(output).to include('Verdict: MISALIGNED')
      expect(output).to include('enable AI for this organisation FIRST')
    end

    # A row whose record is gone is invisible to the reader (the seam INNER JOINs)
    # and unreachable for a reindex — blocking on it would make the gate permanently
    # red behind a fix that does nothing.
    it 'exits ZERO on an orphan row and points at the GC instead of a reindex' do
      organisation = create(:organisation)
      symbol = embedded_symbol(organisation, legacy_space)
      # Callback-free bulk delete — exactly what leaves the sidecar row behind.
      ActsAsTenant.with_tenant(organisation) { CodeSymbol.where(id: symbol.id).delete_all }

      output, exit_error = run_task(organisation.id)

      expect(exit_error).to be_nil
      expect(output).to include('orphan row(s)')
      expect(output).to include('embeddings:gc')
    end
  end

  # Configuration and serving naming DIFFERENT spaces has two opposite causes that are
  # indistinguishable in the data: a switch on its way to the configured space, and a
  # roll-back that deliberately left it behind (the roll-back task says so itself —
  # "the org CONFIGURATION still points at the space you rolled away from").
  #
  # Why these live here and not in space_alignment_spec (review F-A, 2026-08-02): the
  # verdict object only carries the SEVERITY, and that half is pinned over there. The
  # repair ADVICE — the half that was actively wrong, printing `embeddings:flip` alone
  # under a green ALIGNED to an operator coming out of an incident, where the flip is
  # the command that undoes the roll-back — exists only as task output. Every word of
  # it could revert without a red example until these.
  describe 'when configuration and serving name different spaces' do
    before { create(:ai_credential, :active, provider: 'openai') }

    # What the org LOOKS like mid-switch and after a roll-back alike: the pointer serves
    # the default space while the org's own embedding_* columns name another one.
    def diverging_organisation(ai_enabled: true)
      organisation = create(:organisation, ai_enabled: ai_enabled)
      ActsAsTenant.with_tenant(organisation) do
        serving = create(:embedding_space, organisation: organisation, **active_space)
        organisation.update_column(:active_embedding_space_id, serving.id)
      end
      organisation.update!(embedding_provider: 'openai_compatible', embedding_model: 'bge-1536',
                           embedding_api_base: 'https://target.example.test/v1',
                           embedding_access_token: 'sk-target')
      organisation
    end

    # The triple diverging_organisation configures — where NEW content lands.
    let(:target_space) do
      { embedding_provider: 'openai_compatible', embedding_model: 'bge-1536', embedding_dims: 1536 }
    end

    # One record readable in the serving space (so the verdict stays ALIGNED) and one
    # written into the configured space (so pending_flip is non-zero).
    def diverging_corpus(organisation)
      embedded_symbol(organisation, active_space)
      embedded_symbol(organisation, target_space)
    end

    it 'names BOTH repairs and never the flip on its own' do
      organisation = diverging_organisation
      diverging_corpus(organisation)

      output, exit_error = run_task(organisation.id)

      # Not fatal — the intermediate state is legitimate; the gate must not guess which
      # of the two it is looking at.
      expect(exit_error).to be_nil
      expect(output).to include('switch in progress', 'after a roll-back')
      # The wording of the superseded version, which called this a non-issue and printed
      # the roll-back-undoing flip as the single next step.
      expect(output).not_to include('Not a finding')
    end

    # The qualifier has to travel ON the verdict line: a 200-org sweep is read by
    # scanning those lines, and a note further down does not reach that reader.
    it 'carries the divergence qualifier on the VERDICT line itself' do
      organisation = diverging_organisation
      diverging_corpus(organisation)

      output, = run_task(organisation.id)

      verdict_line = output.lines.find { |line| line.include?('Verdict: ALIGNED') }
      expect(verdict_line).to include('configuration and serving diverge')
    end

    # embeddings:build_target resolves its provider through Factory.for_embeddings,
    # which raises AiDisabledError while AI is off — the switch repair is unrunnable
    # there, the roll-back repair (a configuration change) is not.
    it 'says AI must be enabled first before offering the switch repair' do
      organisation = diverging_organisation(ai_enabled: false)
      diverging_corpus(organisation)

      output, exit_error = run_task(organisation.id)

      expect(exit_error).to be_nil
      expect(output).to include('switch in progress → enable AI for this organisation FIRST')
      expect(output).to include('after a roll-back')
    end

    # Two non-blocking findings with OPPOSITE repairs. The closing summary used to
    # describe every warning as "cannot be repaired while AI is off (enable AI, THEN
    # reindex)" — for a diverging org that is the wrong instruction entirely.
    it 'keeps the two kinds of non-blocking finding apart in the closing summary' do
      diverging_corpus(diverging_organisation)
      embedded_symbol(create(:organisation, :ai_disabled), legacy_space)

      output, exit_error = run_task(nil)

      expect(exit_error).to be_nil
      expect(output).to include('2 organisation(s) with a non-blocking finding')
      expect(output).to include('enable AI', 'configuration ≠ serving')
    end
  end

  # A configured space that does not resolve makes the reindex DIE at that very
  # resolution (Embeddings::OrganisationReindexer builds its provider through
  # Factory.for_embeddings(space: :configured)) — so naming the reindex as the fix hands
  # the operator a command that crashes (review R-D, 2026-08-02).
  it 'points at the configuration, not at a reindex, when the CONFIGURED space fails to resolve' do
    create(:ai_credential, :active, provider: 'openai')
    organisation = create(:organisation)
    ActsAsTenant.with_tenant(organisation) do
      serving = create(:embedding_space, organisation: organisation, **active_space)
      organisation.update_column(:active_embedding_space_id, serving.id)
    end
    # No openai_compatible credential exists, so the CONFIGURED space raises while the
    # ACTIVE one still resolves from its own snapshot row.
    organisation.update!(embedding_provider: 'openai_compatible')
    embedded_symbol(organisation, legacy_space)

    output, exit_error = run_task(organisation.id)

    expect(exit_error).to be_a(SystemExit)
    expect(output).to include('CONFIGURED embedding space cannot be resolved')
    expect(output).not_to include('Fix: rake "embeddings:reindex')
  end

  # The verdict is rendered by ONE helper for two consumers. Only :check_alignment is
  # exercised above; this pins that :status — the informational consumer, which also
  # runs the backfill probe and a dry-run GC around it — still renders the same
  # verdict and never aborts on it.
  describe 'the same renderer inside embeddings:status' do
    before { create(:ai_credential, :active, provider: 'openai') }

    it 'prints the alignment verdict informationally, without an exit code' do
      organisation = create(:organisation)
      embedded_symbol(organisation, legacy_space)

      output, exit_error = run_task(organisation.id, name: 'embeddings:status')

      expect(exit_error).to be_nil
      expect(output).to include('Read-path alignment', 'Verdict: MISALIGNED')
    end
  end

  # AI enabled with no resolvable embedding credential: NearestNeighbors raises on
  # every query and PromptBuildingService answers context-free. Nothing is stranded
  # (there is no space to be stranded from), so a verdict built on stranded rows
  # alone would wave this through as green.
  it 'ABORTS when AI is enabled but no embedding credential resolves' do
    organisation = create(:organisation)
    embedded_symbol(organisation, legacy_space)

    output, exit_error = run_task(organisation.id)

    expect(exit_error).to be_a(SystemExit)
    expect(exit_error.status).to eq(1)
    expect(output).to include('Verdict: BROKEN')
  end

  # KI-Pakete P4b precondition 3. An org whose serving space comes from the FALLBACK
  # rather than from its pointer is fully functional today and structurally incapable of
  # a staged switch — its next package change moves reads HARD onto the new, empty space
  # and no flip ever ends it.
  #
  # The gate could not see this before: embedding_space_for returns the configured triple
  # when no pointer resolves, so both sides of every comparison agreed and the verdict
  # came out ALIGNED. These examples pin the finding AND its non-blocking nature.
  context 'the vector-space pointer' do
    before { create(:ai_credential, :active, provider: 'openai') }

    it 'WARNS about a pointerless organisation without failing the gate' do
      organisation = create(:organisation)
      embedded_symbol(organisation, active_space)
      organisation.update_column(:active_embedding_space_id, nil)

      output, exit_error = run_task(organisation.id)

      # Exit ZERO is the decision, not an accident: the state is harmless until the org
      # changes package, and a gate that blocks every deploy over a latent condition
      # stops being read.
      expect(exit_error).to be_nil
      expect(output).to include('Verdict: ALIGNED')
      expect(output).to include('has NO active_embedding_space_id', 'embeddings:backfill_spaces')
    end

    it 'stays quiet once the organisation points at a real space' do
      organisation = create(:organisation)
      embedded_symbol(organisation, active_space)
      space = ActsAsTenant.with_tenant(organisation) do
        create(:embedding_space, organisation: organisation, **active_space)
      end
      organisation.update_column(:active_embedding_space_id, space.id)

      output, exit_error = run_task(organisation.id)

      expect(exit_error).to be_nil
      expect(output).not_to include('active_embedding_space_id')
    end

    # A pointer naming a FOREIGN org's space — the only way in, since a made-up id is
    # refused by the FK and deleting the row nullifies the column instead. Different
    # fault, different repair: running the backfill here would paper over whatever wrote
    # a foreign id in the first place.
    # The suite could not see this before the review: the DB default for ai_enabled is
    # FALSE (schema.rb:859) while the organisation factory sets TRUE, so every example
    # here runs on an AI-enabled org. In production it is the other way round — most orgs
    # never switched AI on, own no spaces, and correctly have no pointer. Warning about
    # them would fire on the whole non-AI fleet at every deploy, which is the exact
    # failure mode this note's own "warn, do not block" argument is about.
    it 'says nothing about an organisation that never switched AI on' do
      organisation = create(:organisation, :ai_disabled)
      embedded_symbol(organisation, active_space)
      organisation.update_column(:active_embedding_space_id, nil)

      output, exit_error = run_task(organisation.id)

      expect(exit_error).to be_nil
      expect(output).not_to include('active_embedding_space_id')
    end

    # A roster line, like every other non-blocking finding in this task. Without it a
    # sweep whose only finding is a missing pointer ends on "No blocking misalignment
    # detected" while the per-org WARNING has scrolled out of view.
    it 'names the affected organisations in the closing summary' do
      organisation = create(:organisation)
      embedded_symbol(organisation, active_space)
      organisation.update_column(:active_embedding_space_id, nil)

      output, = run_task(nil)

      expect(output).to include('serving from the FALLBACK')
      expect(output).to include(organisation.id)
    end

    # No credential (this example opts out of the context's) — the space does not resolve
    # at all, so the org is already reported as BROKEN. Printing the pointer repair on top
    # would send the operator into `backfill_spaces`, which goes through EnsureSpace →
    # embedding_credentials_for and dies on exactly the credential that caused the BROKEN
    # verdict. Same wall switch_repair_line refuses to send anyone into.
    it 'stays quiet when the space does not resolve at all (the repair would fail too)' do
      AiCredential.delete_all
      organisation = create(:organisation)
      embedded_symbol(organisation, active_space)
      organisation.update_column(:active_embedding_space_id, nil)

      output, exit_error = run_task(organisation.id)

      expect(exit_error).to be_a(SystemExit)
      expect(output).to include('Verdict: BROKEN')
      expect(output).not_to include('embeddings:backfill_spaces')
    end

    it 'tells a foreign-space pointer apart from a missing one' do
      organisation = create(:organisation)
      embedded_symbol(organisation, active_space)
      foreign = create(:organisation, name: 'Other', subdomain: 'other-ptr')
      foreign_space = ActsAsTenant.with_tenant(foreign) { create(:embedding_space, organisation: foreign) }
      organisation.update_column(:active_embedding_space_id, foreign_space.id)

      output, exit_error = run_task(organisation.id)

      expect(exit_error).to be_nil
      expect(output).to include('DATA FAULT')
      expect(output).not_to include('embeddings:backfill_spaces')
    end
  end
end
