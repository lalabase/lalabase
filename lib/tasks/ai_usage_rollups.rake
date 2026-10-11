# frozen_string_literal: true

# Operator entry points for the AI consumption rollup (T17,
# doc/billing_agentur_konto_plan.md §17.3b). The scheduled path is
# AiUsageRollupJob; these tasks cover the three things a schedule cannot do:
# take the history that predates the feature, show what is missing, and correct
# a period that was written wrong.
namespace :ai_usage_rollups do
  desc 'Backfill: rollt alle abgeschlossenen Monate mit Verbrauch auf (idempotent)'
  task backfill: :environment do
    first_usage = AiUsage.quota_counted.minimum(:used_at)
    if first_usage.nil?
      puts 'ai_usage_rollups:backfill — kein quota-relevanter Verbrauch vorhanden.'
      next
    end

    period = first_usage.in_time_zone.to_date.beginning_of_month
    last_closed = Time.current.to_date.beginning_of_month.prev_month
    inserted = 0
    skipped = 0

    while period <= last_closed
      result = Subscriptions::AiUsageAggregator.call(period_start: period)
      puts format('  %<period>s — %<inserted>d Rollup(s), %<skipped>d ohne Account',
                  period: period, inserted: result.inserted, skipped: result.skipped_without_account)
      inserted += result.inserted
      skipped += result.skipped_without_account
      period = period.next_month
    end

    puts "ai_usage_rollups:backfill — #{inserted} Rollup(s) geschrieben, #{skipped} uebersprungen."
    puts 'Hinweis: uebersprungen = Organisation ohne Account. `rake accounts:backfill`, dann erneut.' if skipped.positive?
  end

  desc 'Zeigt abgeschlossene Perioden mit Verbrauch, aber ohne Rollup-Zeile'
  task :gaps, [:months] => :environment do |_task, args|
    months = (args[:months] || 6).to_i
    gaps = Subscriptions::AiUsageAggregator.missing_periods(months: months)

    if gaps.empty?
      puts "ai_usage_rollups:gaps — keine Luecken in den letzten #{months} Monaten."
      next
    end

    puts "ai_usage_rollups:gaps — #{gaps.size} Luecke(n):"
    gaps.each { |gap| puts "  #{gap[:period_start]}  Organisation #{gap[:organisation_id]}" }
  end

  # The ONLY path allowed to overwrite a settled period. Everything else is
  # write-once on purpose (a re-run must never be able to shrink history when a
  # credential was deleted or flipped out of the quota). Deleting first is
  # therefore explicit, logged, and asked for by hand.
  #
  # Two things must happen BEFORE the delete, both learned the hard way
  # (review findings K1/K2):
  #
  #   1. Refuse an open period. The aggregator refuses to roll one -- but that
  #      refusal used to come AFTER the delete, so rebuilding the running month
  #      deleted the flush rows of deleted organisations and then aborted with
  #      nothing written.
  #   2. Never touch orphaned rows. Once an organisation is gone its ai_usages
  #      are gone with it, so a rollup of that organisation CANNOT be recomputed
  #      -- it is the only copy. delete_all took them along regardless.
  #
  # Everything runs in one transaction, so a failure between delete and write
  # leaves the period as it was.
  desc 'Korrektur: loescht eine Periode und schreibt sie neu — rebuild[2026-07-01]'
  task :rebuild, [:period_start] => :environment do |_task, args|
    abort 'Nutzung: rake "ai_usage_rollups:rebuild[2026-07-01]"' if args[:period_start].blank?

    period = Date.parse(args[:period_start]).beginning_of_month
    aggregator = Subscriptions::AiUsageAggregator
    abort "ai_usage_rollups:rebuild — #{aggregator.open_period_message(period)}" unless aggregator.closed_period?(period)

    scope = AiUsageRollup.for_period(period)
    protected_count = scope.orphaned.count

    deleted = 0
    result = nil
    ActiveRecord::Base.transaction do
      deleted = scope.rebuildable.delete_all
      Rails.logger.warn(
        "ai_usage_rollups:rebuild — #{deleted} Rollup(s) fuer #{period} geloescht " \
        "(manuelle Korrektur, #{protected_count} verwaiste geschuetzt)"
      )
      # NOT .call: that entry point is the monthly job's and hardwires
      # on_failure: :warn, which swallows a failed write. Inside a transaction
      # that has already deleted, a swallowed failure is the worst possible
      # outcome: no error reaches the transaction, it commits, and the period is
      # gone with nothing written in its place. :raise is what makes the
      # all-or-nothing promise above true. The closed-period guard that .call
      # would add is already enforced further up, before the delete (K2).
      result = aggregator.new.aggregate(period_start: period, on_failure: :raise)
    end

    puts "ai_usage_rollups:rebuild — #{period}: #{deleted} geloescht, #{result.inserted} neu geschrieben."
    if protected_count.positive?
      puts "  #{protected_count} Zeile(n) unberuehrt gelassen: die Organisation ist geloescht, " \
           'ihr Verbrauch ist nicht rekonstruierbar.'
    end
    if result.inserted < deleted
      puts 'WARNUNG: weniger Zeilen als vorher. Moegliche Ursache: Credential geloescht oder aus der ' \
           'Quota genommen (quota_counted joint ai_credentials).'
    end
  end
end
