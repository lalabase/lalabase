# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require 'tmpdir'

# What: the `plan_status` rake task — the machine-written "Umsetzung" marker on every doc/*.md.
# Why:  the task's value rests on two behavioural promises, and NEITHER is visible in its
#       output on a good day:
#         1. IDEMPOTENCE — a rerun with unchanged evidence must produce an empty diff.
#            Without it `plan_status:check` cannot tell "nothing shipped" from "everything
#            changed", which is the entire point of a drift check.
#         2. REFUSAL over silent success — every failure mode of this task (typo'd path,
#            saturated PR list, failing git) resembles a clean run: an empty result set reads
#            as "alle Marker aktuell". Each of those paths must `abort`.
#       A regression in either is invisible: markers would still be written, the task would
#       still exit 0, and the damage (a sweeping diff nobody triggered, or a plan silently
#       downgraded to "kein Beleg") only shows up in review of an unrelated PR.
# Pattern: follows spec/lib/tasks/embeddings_check_alignment_spec.rb — load tasks once, read
#       the SystemExit that `abort` raises. The plan directory is stubbed to a tmpdir so the
#       examples never depend on (or write to) the repo's real 132 plans; `commits_for` is
#       stubbed because git cannot log a path outside the repository.
RSpec.describe 'plan_status (Umsetzungs-Marker)' do
  # After the private-docs move, a zero-plan success would falsely certify the archive.
  [false, true].each do |write|
    it "refuses a missing archive before querying GitHub (write: #{write})" do
      missing = File.join(@dir, 'moved-private-archive')
      stub_const('PlanStatus::PLAN_DIR', missing)
      stub_const('PlanStatus::PLAN_GLOB', "#{missing}/*.md")
      expect(PlanStatus).not_to receive(:pull_requests)

      expect { PlanStatus.run(write: write) }
        .to raise_error(SystemExit, /lalabase-private/)
      expect(Dir.exist?(missing)).to be false
    end
  end

  before(:all) do
    # Idempotent: loading twice would define the task bodies a second time.
    Rails.application.load_tasks unless Rake::Task.task_defined?('plan_status:refresh')
  end

  # around creates the directory, before does the stubbing: rspec-mocks is not available
  # inside an around hook (it lives outside the per-example lifecycle).
  around do |example|
    Dir.mktmpdir('plan_status_spec') do |dir|
      @dir = dir
      example.run
    end
  end

  # No PRs and no commits => the "kein Beleg" branch, whose wording is stable and whose
  # evidence cannot drift between the two runs of the idempotence example.
  before do
    stub_const('PlanStatus::PLAN_DIR', @dir)
    stub_const('PlanStatus::PLAN_GLOB', "#{@dir}/*.md")
    allow(PlanStatus).to receive_messages(pull_requests: {}, commits_for: [])
  end

  def write_plan(name, body)
    File.write(File.join(@dir, name), body)
  end

  def read_plan(name)
    File.read(File.join(@dir, name))
  end

  describe 'idempotence — the property `check` depends on' do
    it 'leaves the file byte-identical on a second run with unchanged evidence' do
      write_plan('a.md', "# Titel\n\nText.\n")

      PlanStatus.run(write: true)
      after_first = read_plan('a.md')
      PlanStatus.run(write: true)

      expect(read_plan('a.md')).to eq(after_first)
    end

    it 'reports nothing to do on the second run' do
      write_plan('a.md', "# Titel\n\nText.\n")
      PlanStatus.run(write: true)

      expect(PlanStatus.run(write: false)).to be_empty
    end

    # The block carries its own PR numbers; reading the header WITH the block would let a
    # marker promote itself from "unklar" to "belegt" and never fall back.
    it 'does not feed its own PR numbers back into the header signal' do
      prs = { 42 => { 'number' => 42, 'state' => 'MERGED', 'title' => 'feat: irgendwas' } }
      allow(PlanStatus).to receive(:pull_requests).and_return(prs)
      write_plan('b.md', "# Titel\n\nBezug: #42\n")

      PlanStatus.run(write: true)
      first = read_plan('b.md')
      PlanStatus.run(write: true)

      expect(read_plan('b.md')).to eq(first)
    end

    # A marker removed by hand must round-trip to the original bytes, not to a doubled blank
    # line -- otherwise every rerun after a manual edit produces phantom diffs.
    it 'replaces a previous block instead of stacking a second one' do
      write_plan('c.md', "# Titel\n\nText.\n")
      PlanStatus.run(write: true)
      PlanStatus.run(write: true)

      expect(read_plan('c.md').scan(PlanStatus::MARK_CLOSE).size).to eq(1)
    end
  end

  describe 'refusal instead of silent success' do
    it 'aborts when the pattern matches no plan' do
      write_plan('a.md', "# Titel\n")

      expect { PlanStatus.paths('gibtsnicht.md') }
        .to raise_error(SystemExit).and output(/kein Plan passt/).to_stderr
    end

    # The pattern must MATCH to reach the guard — a relative "../x.md" resolves against the
    # working directory (the Rails root), matches nothing there and would trip the
    # empty-match abort instead. An absolute path outside PLAN_DIR is the honest case.
    it 'aborts when the pattern escapes the plan directory' do
      outside = File.join(@dir, '..', "escape_#{Process.pid}.md")
      File.write(outside, "# Draußen\n")

      expect { PlanStatus.paths(outside) }
        .to raise_error(SystemExit).and output(/außerhalb/).to_stderr
    ensure
      File.delete(outside) if outside && File.exist?(outside)
    end

    # `gh pr list` returns newest first, so a saturated list is missing the OLDEST PRs --
    # exactly the ones old plans reference. Writing from it would restamp dozens of markers.
    it 'aborts when the PR list comes back saturated' do
      allow(PlanStatus).to receive(:pull_requests).and_call_original
      stub_const('PlanStatus::PR_LIMIT', 2)
      saturated = Array.new(2) { |i| { 'number' => i, 'state' => 'MERGED', 'title' => 'feat: x' } }
      allow(PlanStatus).to receive(:`).and_return(saturated.to_json)

      expect { PlanStatus.pull_requests }
        .to raise_error(SystemExit).and output(/abgeschnitten/).to_stderr
    end

    it 'accepts a bare filename by resolving it inside the plan directory' do
      write_plan('a.md', "# Titel\n")

      expect(PlanStatus.paths('a.md')).to eq([File.join(@dir, 'a.md')])
    end
  end

  # The marker records EVIDENCE, never a verdict: "kein Beleg" must not read as "not
  # implemented", because implementation can be proven automatically but not disproven.
  describe 'wording of the no-evidence case' do
    it 'states explicitly that it is not proof of non-implementation' do
      write_plan('a.md', "# Titel\n")
      PlanStatus.run(write: true)

      expect(read_plan('a.md')).to include('kein Nachweis, dass nichts umgesetzt wurde')
    end
  end
end
