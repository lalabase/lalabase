# frozen_string_literal: true

# Backfill tasks for the Fälligkeit (due date) + priority-level feature. Both are
# idempotent and reversible; the priority-level backfill is the only production-data
# mutation and is intentionally NOT part of any schema migration (run it separately so a
# failure cannot block the feature deploy). See doc/faelligkeit_due_date_plan.md §11 (T4=A).
namespace :tickets do
  desc 'Provision the default due_date field into existing projects (idempotent, reconciliation-aware)'
  task backfill_due_date: :environment do
    result = Projects::DueDateBackfillService.call
    puts "[due_date backfill] created=#{result.created} existed=#{result.existed} " \
         "conflicts=#{result.conflicts} failed=#{result.failed}"
  end

  desc 'Revert due_date provisioning (removes auto-provisioned fields; tickets keep their values)'
  task backfill_due_date_revert: :environment do
    removed = Projects::DueDateBackfillService.revert
    puts "[due_date backfill revert] removed=#{removed}"
  end

  desc 'Backfill explicit priority levels from current option order (idempotent, reversible)'
  task backfill_priority_levels: :environment do
    result = Projects::PriorityLevelBackfillService.call
    puts "[priority levels backfill] updated=#{result.updated} skipped=#{result.skipped} failed=#{result.failed}"
  end

  desc 'Revert priority-level backfill (strips level keys back out)'
  task backfill_priority_levels_revert: :environment do
    reverted = Projects::PriorityLevelBackfillService.revert
    puts "[priority levels backfill revert] reverted=#{reverted}"
  end
end
