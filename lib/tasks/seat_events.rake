# frozen_string_literal: true

# Operator entry points for the seat event stream (M0b,
# doc/abrechnungsmodell_plan.md §3). The scheduled path is SeatEventRecording on
# the membership callbacks; these two tasks cover what a callback cannot do:
# lay down the starting state the stream never had, and say whether it still
# agrees with reality.
namespace :seat_events do
  desc 'Eroeffnungsstand nachtragen (DRY_RUN=1 zeigt nur an). Idempotent.'
  task backfill_openings: :environment do
    dry_run = ENV['DRY_RUN'] == '1'
    result = Subscriptions::SeatOpeningBackfill.call(dry_run: dry_run)

    puts format('seat_events:backfill_openings%<mode>s', mode: dry_run ? ' (DRY_RUN)' : '')
    puts format('  %<pairs>d gezaehlte Mitgliedschaften geprueft', pairs: result.pairs_seen)
    puts format('  %<written>d Eroeffnungen%<verb>s, %<accounts>d Konten betroffen, Stand %<at>s',
                written: result.written, verb: dry_run ? ' waeren zu schreiben' : ' geschrieben',
                accounts: result.accounts_touched, at: result.at.iso8601)

    if result.written.zero?
      puts '  Nichts zu tun. Entweder ist der Eroeffnungsstand schon gesetzt, oder es gibt ' \
           'keine gezaehlten Mitgliedschaften.'
    end

    # The run is only worth anything if the stream agrees afterwards, so the
    # check is not a separate ritual the operator has to remember.
    #
    # reenable first, and that is load-bearing: Rake::Task#invoke is a NO-OP once
    # the task has run in this process. `rake seat_events:verify
    # seat_events:backfill_openings` is the obvious operator sequence (look, then
    # fix), and without this the backfill would silently skip its own check
    # exactly there.
    unless dry_run
      Rake::Task['seat_events:verify'].reenable
      Rake::Task['seat_events:verify'].invoke
    end
  end

  desc 'Prueft je Konto: Rekonstruktion aus dem Strom gegen SeatCounter'
  task verify: :environment do
    findings = Subscriptions::SeatStreamDrift.call

    if findings.empty?
      puts 'seat_events:verify: Strom und SeatCounter stimmen fuer jedes Konto ueberein.'
      next
    end

    # Loud and non-zero: as long as the two disagree, no figure from the stream
    # may reach an invoice (§3). A task that merely printed would let a nightly
    # run swallow that.
    puts format('seat_events:verify: %<n>d Konto/Konten mit Befund.', n: findings.size)
    findings.each do |finding|
      name = finding.account.name[0, 34]
      # Three kinds of finding, three lines. A single format would not only be
      # ugly here: `from_stream` is deliberately nil for the other two kinds, and
      # formatting a 0 into it would be a number nobody measured.
      puts case finding.kind
           when Subscriptions::SeatStreamDrift::KIND_FAILED
             format('  %<name>-34s FEHLER %<error>s', name: name, error: finding.error)
           when Subscriptions::SeatStreamDrift::KIND_NOT_RECONSTRUCTIBLE
             format('  %<name>-34s live=%<live>d, Strom hat fuer diesen Zeitpunkt keine Grundlage',
                    name: name, live: finding.live)
           else
             format('  %<name>-34s live=%<live>d strom=%<stream>d (%<diff>+d)',
                    name: name, live: finding.live,
                    stream: finding.from_stream, diff: finding.difference)
           end
    end
    abort('Abweichung zwischen Ereignisstrom und SeatCounter. Auf dieser Grundlage darf nicht abgerechnet werden.')
  end
end
