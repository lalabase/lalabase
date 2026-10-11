# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: the `ai_usage_rollups:rebuild` correction task (T17).
# Type: Rake task spec.
# Why:  rebuild is the only path allowed to overwrite a settled period, which
#       makes it the only path that can DESTROY one. Two of its failure modes
#       look like success from the outside and were both measured on the merged
#       code (review findings K1/K2):
#
#         K1 — a rollup whose organisation is deleted is the ONLY copy of that
#              consumption (its ai_usages died with the org). delete_all took it
#              along, and the re-aggregation could not write it back: 0 rows,
#              exit 0, no error.
#         K2 — the open-period refusal lived in the aggregator, i.e. AFTER the
#              delete. Rebuilding the running month wiped the flush rows and
#              then aborted, leaving nothing behind.
#
#       Both are silent on a good day, so they are pinned here rather than left
#       to the task's own puts output.
RSpec.describe 'ai_usage_rollups:rebuild' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('ai_usage_rollups:rebuild')
  end

  before { Rake::Task['ai_usage_rollups:rebuild'].reenable }

  let(:organisation) { create(:organisation) }
  let(:credential) { create(:ai_credential) }
  let(:last_month) { Date.current.prev_month.beginning_of_month }

  def run_rebuild(period)
    Rake::Task['ai_usage_rollups:rebuild'].invoke(period.to_s)
  end

  it 'rewrites a period whose organisation still exists' do
    create(:ai_usage, organisation: organisation, ai_credential: credential,
                      used_at: last_month + 5.days, credits_used: 7, tokens_used: 10, cost_cents: 2)
    create(:ai_usage_rollup, account: organisation.account, organisation_id: organisation.id,
                             period_start: last_month, credits_used: 999)

    expect { run_rebuild(last_month) }.to output(/1 geloescht, 1 neu geschrieben/).to_stdout

    expect(AiUsageRollup.sole.credits_used).to eq(7)
  end

  # K1: the row is irreplaceable — there are no ai_usages left to recompute it
  # from. Deleting it is not a correction, it is data loss.
  it 'leaves a rollup whose organisation is gone untouched' do
    orphan = create(:ai_usage_rollup, period_start: last_month, credits_used: 42)

    expect { run_rebuild(last_month) }
      .to output(/1 Zeile\(n\) unberuehrt gelassen/).to_stdout

    expect(orphan.reload.credits_used).to eq(42)
  end

  it 'rewrites the rebuildable rows in the same period without touching the orphan' do
    create(:ai_usage, organisation: organisation, ai_credential: credential,
                      used_at: last_month + 5.days, credits_used: 7, tokens_used: 10, cost_cents: 2)
    create(:ai_usage_rollup, account: organisation.account, organisation_id: organisation.id,
                             period_start: last_month, credits_used: 999)
    orphan = create(:ai_usage_rollup, period_start: last_month, credits_used: 42)

    run_rebuild(last_month)

    expect(AiUsageRollup.count).to eq(2)
    expect(orphan.reload.credits_used).to eq(42)
    expect(AiUsageRollup.where(organisation_id: organisation.id).sole.credits_used).to eq(7)
  end

  # K2: the refusal has to come BEFORE the delete, or the abort leaves a hole.
  #
  # The row deliberately belongs to a LIVING organisation. With the factory
  # default (a random organisation_id, i.e. an orphan) it would sit outside
  # `rebuildable` and could not be deleted no matter where the guard stands:
  # the example would pass on K1's protection and prove nothing about ordering.
  it 'refuses the running month without deleting anything first' do
    current_period = Date.current.beginning_of_month
    flushed = create(:ai_usage_rollup, account: organisation.account,
                                       organisation_id: organisation.id,
                                       period_start: current_period, credits_used: 5, partial: true)

    expect { run_rebuild(current_period) }.to raise_error(SystemExit)

    expect(flushed.reload.credits_used).to eq(5)
  end

  # The task promises all-or-nothing. That promise only holds if the write
  # RAISES: the monthly job's entry point swallows a failed account write, and a
  # swallowed failure inside a transaction that has already deleted commits the
  # deletion with nothing to replace it.
  it 'keeps the period as it was when the rewrite fails' do
    create(:ai_usage, organisation: organisation, ai_credential: credential,
                      used_at: last_month + 5.days, credits_used: 7, tokens_used: 10, cost_cents: 2)
    existing = create(:ai_usage_rollup, account: organisation.account,
                                        organisation_id: organisation.id,
                                        period_start: last_month, credits_used: 999)
    allow(AiUsageRollup).to receive(:insert_all).and_raise(TypeError, 'boom')

    expect { run_rebuild(last_month) }.to raise_error(TypeError)

    expect(existing.reload.credits_used).to eq(999)
  end
end
