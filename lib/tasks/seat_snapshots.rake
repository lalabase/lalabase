# frozen_string_literal: true

# Operator entry points for the month-boundary seat snapshots (M1b,
# doc/abrechnungsmodell_plan.md §4; T18 in doc/billing_agentur_konto_plan.md
# §17.3). The scheduled path is SeatSnapshotJob; these tasks cover what a
# schedule cannot do: lay down the boundaries that predate the feature, show
# what is missing, and correct a boundary that was computed on an incomplete
# stream.
namespace :seat_snapshots do
  # Every boundary from the stream's opening up to the current month. Earlier
  # boundaries are deliberately NOT written: before the opening marker no
  # account is reconstructible, so each row would say "cannot be known" back to
  # the beginning of time and tell nobody anything.
  #
  # This is a rule about the UNBOUNDED past, not a claim that a pre-marker
  # boundary must stay empty. SeatSnapshotJob fills its whole window including
  # those months, and rightly so: inside the window a gap is an alarm, so
  # "cannot be known" has to be written down rather than left absent. The task
  # only refuses to walk backwards forever.
  desc 'Legt alle Monatsgrenzen ab dem Eroeffnungsstand an (idempotent)'
  task backfill: :environment do
    opened_at = SystemSetting.seat_stream_opened_at
    if opened_at.nil?
      abort 'seat_snapshots:backfill: Es gibt keinen Eroeffnungsstand. ' \
            'Zuerst `rake seat_events:backfill_openings`.'
    end

    period = opened_at.in_time_zone(Subscriptions::Constants::BILLING_TIME_ZONE)
                      .to_date.beginning_of_month
    # The month the marker falls into is not reconstructible at its own
    # boundary: the boundary is midnight, the marker came later that month.
    period = period.next_month
    last = Subscriptions::SeatSnapshotWriter.current_boundary_month

    if period > last
      puts format('seat_snapshots:backfill: Noch keine abgeschlossene Monatsgrenze nach dem ' \
                  'Eroeffnungsstand (%<at>s). Die naechste ist der %<next>s.',
                  at: opened_at.iso8601, next: period)
      next
    end

    written = 0
    while period <= last
      # opened_at is passed along: the task already holds the marker, and the
      # loop would otherwise re-read the same system setting once per month.
      result = Subscriptions::SeatSnapshotWriter.fill(period_start: period, opened_at: opened_at)
      puts format('  %<period>s  %<written>d geschrieben, %<unknown>d nicht rekonstruierbar, ' \
                  '%<failed>d fehlgeschlagen',
                  period: period, written: result.written,
                  unknown: result.not_reconstructible, failed: result.failed)
      written += result.written
      period = period.next_month
    end

    puts "seat_snapshots:backfill: #{written} Grenze/Konto-Paar(e) neu beantwortet."
  end

  desc 'Zeigt Monatsgrenzen ohne Antwort - gaps[6]'
  task :gaps, [:months] => :environment do |_task, args|
    months = (args[:months] || SeatSnapshotJob::CATCH_UP_MONTHS).to_i
    gaps = Subscriptions::SeatSnapshotWriter.gaps(months: months)

    if gaps.empty?
      puts "seat_snapshots:gaps: keine Luecken in den letzten #{months} Monaten."
      next
    end

    puts "seat_snapshots:gaps: #{gaps.size} Luecke(n):"
    gaps.each { |gap| puts "  #{gap[:period_start]}  Konto #{gap[:account_id]}" }
  end

  # The correction path after a backdated event was appended (§9). Unlike
  # `ai_usage_rollups:rebuild` this deletes NOTHING and needs no transaction:
  # snapshots are derived and overwriting them in place IS the supported
  # operation, while a rollup's source can be gone and a delete there is
  # irreversible. Two tables, two rules, and confusing them would either freeze a
  # snapshot that must move or destroy a rollup that cannot come back.
  desc 'Korrektur: rechnet eine Monatsgrenze neu - rebuild[2026-09-01]'
  task :rebuild, [:period_start] => :environment do |_task, args|
    abort 'Nutzung: rake "seat_snapshots:rebuild[2026-09-01]"' if args[:period_start].blank?

    # The SAME precondition the backfill has, and it belongs here even more:
    # without a marker nothing is reconstructible, so a rebuild would replace
    # every measured row of the boundary with "cannot be known" and report
    # success. The destructive task must not be the one without the guard.
    opened_at = SystemSetting.seat_stream_opened_at
    if opened_at.nil?
      abort 'seat_snapshots:rebuild: Es gibt keinen Eroeffnungsstand. Ein Lauf wuerde jede ' \
            'gemessene Zeile dieser Grenze durch "nicht rekonstruierbar" ersetzen. ' \
            'Zuerst `rake seat_events:backfill_openings`.'
    end

    # ONE strict format, and the result has to round-trip back to what was
    # typed. This is the only task that overwrites an answered row, so it must
    # rebuild the boundary the operator NAMED, and both obvious readers are
    # helpful in the wrong direction: Date.parse turns "09-01-2026" into the 9th
    # of JANUARY, and Date.strptime reads the same string as the year 9. Either
    # way a slip in the field order silently corrects a boundary nobody asked
    # about. Comparing the parsed date back to the input is what catches it.
    given = args[:period_start]
    parsed = begin
      Date.strptime(given, '%Y-%m-%d')
    rescue Date::Error
      nil
    end
    if parsed.nil? || parsed.to_s != given
      abort "seat_snapshots:rebuild: #{given.inspect} ist kein Datum im Format JJJJ-MM-TT. " \
            'Nutzung: rake "seat_snapshots:rebuild[2026-09-01]"'
    end

    period = parsed.beginning_of_month

    # Asked before the writer is built, so the answer is one German line like
    # every other refusal of this task. Letting the writer's ArgumentError
    # escape would print an English sentence, and catching it here would need a
    # rescue wide enough to swallow unrelated ArgumentErrors too.
    if period > Subscriptions::SeatSnapshotWriter.current_boundary_month
      abort "seat_snapshots:rebuild: Die Grenze #{period} liegt in der Zukunft, ihr Zustand " \
            'existiert noch nicht. Zuletzt moeglich ist die laufende Monatsgrenze.'
    end

    result = Subscriptions::SeatSnapshotWriter.call(period_start: period, opened_at: opened_at)

    Rails.logger.warn(
      "#{Subscriptions::Constants::SEAT_SNAPSHOT_LOG_PREFIX} rebuild: Grenze #{period} fuer " \
      "#{result.outcomes.size} Konto/Konten neu gerechnet (manuelle Korrektur)"
    )
    puts format('seat_snapshots:rebuild: %<period>s neu gerechnet. %<written>d gemessen, ' \
                '%<unknown>d nicht rekonstruierbar, %<failed>d fehlgeschlagen.',
                period: period, written: result.written,
                unknown: result.not_reconstructible, failed: result.failed)

    next if result.failed.zero?

    # A failure here is not cosmetic. The writer keeps an already answered row
    # rather than replacing it with the failure, so the table still holds a
    # value -- but it is the OLD one, the very one this run was called to
    # correct. Exiting 0 would report the correction as done.
    #
    # And because that row was kept, its `error` column says nothing: the reason
    # exists only in the outcome. Naming it here is therefore not a nicety, it
    # is the only place the operator can learn WHICH account failed and why.
    Subscriptions::SeatSnapshotWriter.log_failures(result)
    abort 'Mindestens ein Konto konnte nicht gerechnet werden. Details im Log.'
  end
end
