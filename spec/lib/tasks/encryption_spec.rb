# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: the rake task `encryption:reencrypt_tokens` — the GATE in front of the
#       irreversible key-rotation step (removing the previous READ scheme).
# Why:  the task's entire value is its EXIT CODE plus an honest summary. The
#       operator's runbook step is literally "verify it reports zero skipped
#       rows, then delete the PREVIOUS_* variables" — so `abort` degrading to
#       `puts`, the failed-counter accumulation being dropped, or an EMPTY
#       registry sweeping nothing and printing a bare success line would each
#       green-light permanent data loss without a single example turning red.
#       Row semantics live in the concern's model specs; THIS file pins only
#       the gate. Pattern: spec/lib/tasks/embeddings_check_alignment_spec.rb.
RSpec.describe 'encryption:reencrypt_tokens' do
  before(:all) do
    # Idempotent: loading twice would append the task bodies a second time and
    # run every action twice.
    Rails.application.load_tasks unless Rake::Task.task_defined?('encryption:reencrypt_tokens')
    # The task eager-loads for itself, but stub_sweeps iterates the registry
    # BEFORE the task runs — in an isolated run of this file the registry would
    # still be empty at stub time, no stub would attach, and the examples would
    # exercise the real sweeps against whatever the test DB holds.
    Rails.application.eager_load!
  end

  # The real rake process runs without an ambient tenant.
  before { ActsAsTenant.current_tenant = nil }

  # @return [Array(String, SystemExit, nil)] captured stdout + the SystemExit
  #   `abort` raised (nil on a clean run)
  def run_task
    task = Rake::Task['encryption:reencrypt_tokens']
    task.reenable
    stdout = StringIO.new
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = stdout
    $stderr = StringIO.new # abort() writes its message here; keep the suite quiet
    begin
      task.invoke
      [stdout.string, nil]
    rescue SystemExit => e
      [stdout.string, e]
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end
  end

  # Stub the sweep on every registered model: this file pins the task's gate,
  # not the row semantics (those live in the concern's model specs).
  def stub_sweeps(results)
    TokenReencryptable.registry.each_key do |class_name|
      allow(class_name.constantize).to receive(:reencrypt_tokens!)
        .and_return(results.fetch(class_name, { processed: 0, failed: 0 }))
    end
  end

  it 'exits ZERO and names every registered table when nothing was skipped' do
    stub_sweeps('ProjectRepository' => { processed: 2, failed: 0 })

    output, exit_error = run_task

    expect(exit_error).to be_nil
    # The registry must be populated at task time (eager_load ran) and every
    # registered table must appear in the summary — the operator reads THIS
    # line to decide whether the rotation may proceed. The numbers themselves
    # are part of the contract ("2 von N, 0 uebersprungen"), not just the
    # table names: a summary printing constants would otherwise stay green.
    expect(TokenReencryptable.registry).not_to be_empty
    TokenReencryptable.registry.each_key do |class_name|
      expect(output).to include(class_name.constantize.table_name)
    end
    expect(output).to match(/project_repositories: 2 von \d+ neu verschluesselt, 0 uebersprungen/)
  end

  it 'aborts with a non-zero exit as soon as one registered model reports a skipped row' do
    stub_sweeps('ProjectRepository' => { processed: 1, failed: 1 })

    _output, exit_error = run_task

    expect(exit_error).not_to be_nil
    expect(exit_error.status).to eq(1)
    expect(exit_error.message).to include('uebersprungen')
  end

  it 'aborts when a NON-last registered model fails while the last one succeeds (accumulation, not assignment)' do
    # ProjectRepository sorts LAST in registry.keys.sort — an example failing
    # only there cannot tell `failed_total += result[:failed]` apart from a
    # plain assignment. Admin::AiCredential sorts FIRST, and the runbook names
    # its rows as the most likely real-world skip: the failure must survive
    # every later, clean table into the exit code.
    stub_sweeps(
      'Admin::AiCredential' => { processed: 0, failed: 1 },
      'ProjectRepository' => { processed: 2, failed: 0 }
    )

    _output, exit_error = run_task

    expect(exit_error).not_to be_nil
    expect(exit_error.status).to eq(1)
    expect(exit_error.message).to include('1 Zeile(n) uebersprungen')
  end

  it 'aborts on an EMPTY registry instead of reporting a vacuous success' do
    # An empty sweep printing a bare success line would green-light the
    # irreversible removal of the previous READ scheme with zero rows rewritten.
    allow(TokenReencryptable).to receive(:registry).and_return({})

    _output, exit_error = run_task

    expect(exit_error).not_to be_nil
    expect(exit_error.status).to eq(1)
    expect(exit_error.message).to include('Registry')
  end
end
