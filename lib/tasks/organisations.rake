# frozen_string_literal: true

# Operator entry point for the one-off copy behind step 4 of
# doc/projekt_chat_abbau_plan.md: `project_chat_enabled` -> `code_indexing_enabled`.
#
# POSITION IN THE SEQUENCE, and it is load-bearing:
#
#   1. Deploy release 1 (migration adds the new column, all false)
#   2. rake organisations:backfill_code_indexing DRY_RUN=1   look at it
#   3. rake organisations:backfill_code_indexing             copy
#   4. Deploy release 2 (reads ONLY the new column)
#
# Whoever deploys 4 before 3 turns off code indexing for every organisation that has
# it. Production finished the run on 31.08.2026 (6 organisations); the task stays for
# environments that still have the jump ahead of them: development, staging and every
# self-hosted instance that updates from before release 1 to release 2.
#
# ⚠️ RAW SQL for the old column, since release 2. It is in `ignored_columns`
# (Organisation AND Admin::Organisation), so that the DROP in release 3 does not open a
# 500 window, and a model that ignores a column cannot query it either.
# This is the same design as in `chats:backfill_scope_references`: a task whose
# subject is a legacy column reads it where it still exists.
#
# Release 3 deletes the column and this task with it.
#
# Idempotent: a second run costs nothing. The task only copies in one direction
# (old to new) and does not touch an organisation whose new column is already right.
# An operator who switches in the admin area after step 3 therefore does not lose the
# change if the task runs again.
namespace :organisations do
  # The old column is in ignored_columns since release 2, so ActiveRecord cannot query
  # it. Raw SQL, scoped to the one column and the one value, is the honest way to read
  # a legacy column that is on its way out.
  def legacy_enabled_ids
    Organisation.connection.select_values(
      'SELECT id FROM organisations WHERE project_chat_enabled = TRUE'
    )
  end

  desc 'Kopiert project_chat_enabled nach code_indexing_enabled (DRY_RUN=1 zeigt nur an). Idempotent.'
  task backfill_code_indexing: :environment do
    dry_run = ENV['DRY_RUN'].present?

    ActsAsTenant.without_tenant do
      pending = Organisation.where(id: legacy_enabled_ids).where(code_indexing_enabled: false)
      names = pending.order(:name).pluck(:name)

      puts format('organisations:backfill_code_indexing%<mode>s', mode: dry_run ? ' (DRY_RUN)' : '')
      puts format('  %<n>d Organisationen%<verb>s umgestellt', n: names.size, verb: dry_run ? ' waeren' : '')
      names.each { |name| puts "    - #{name}" }

      # ⚠️ Deliberately NOT reported as an error: an organisation whose new column is
      # already true and whose old one is false is an operator toggle made AFTER the
      # deploy, which is exactly the state this task must not undo.
      ahead = Organisation.where(code_indexing_enabled: true).where.not(id: legacy_enabled_ids).count
      puts format('  %<n>d bereits nur ueber die neue Spalte (unangetastet)', n: ahead) if ahead.positive?

      next if dry_run

      pending.update_all(code_indexing_enabled: true)
      remaining = Organisation.where(id: legacy_enabled_ids).where(code_indexing_enabled: false).count
      puts format('  %<n>d danach noch offen (muss 0 sein)', n: remaining)
    end
  end
end
