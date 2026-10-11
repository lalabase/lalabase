# frozen_string_literal: true

# Operator entry points for the monthly peak (M2/M3,
# doc/abrechnungsmodell_plan.md A2/A3/§5). Nothing here writes: the boundary rows
# come from SeatSnapshotJob and seat_snapshots:*, and this only asks. Two
# questions, because there are two jobs: `month` is the operator's overview
# before an invoicing round, `show` is the support answer to "why does it say
# five".

# In a module rather than as bare `def`s in the rake file: a top-level def there
# lands on Object and is then visible from every other task in the process.
module SeatPeakTaskOutput
  module_function

  # Reason texts come from I18n, the SAME keys the admin page renders. Written
  # twice they would drift, and then the screen and the console would explain
  # one state in two ways.
  def status_text(result)
    return I18n.t("admin.seat_peak.reason.#{result.reason_key}") unless result.ok?

    section = result.sections.first
    text = result.detailed?(section) ? split_summary(result) : single_summary(section)
    result.provisional? ? "#{text} (#{I18n.t('admin.seat_peak.provisional_short')})" : text
  end

  # The everyday month: the peak and since when. Kept in its own shape because an
  # overview of nine accounts is read at a glance, and "seit" answers the
  # question an operator actually has.
  #
  # Only for a section that really covers the WHOLE month. A billing start on
  # the 28th also gives exactly one section, and printing it like a full month
  # is the first invoice of every new customer read wrong (review finding
  # on #533).
  def single_summary(section)
    format('%<peak>d, seit %<at>s', peak: section.peak, at: moment(section.peak_at))
  end

  # Sections with their stretches. Days come along: the reader has to see that
  # these share ONE month, or cover only part of it.
  def split_summary(result)
    result.sections.map { |section| "#{section.peak} (#{section_span(section)})" }.join(', ')
  end

  def section_span(section)
    format('%<from>s bis %<to>s, %<days>d T.',
           from: section.first_day.strftime('%d.%m.'), to: section.last_day.strftime('%d.%m.'),
           days: section.days)
  end

  # "Ganzer Monat" is claimed only when it is TRUE. A lone four-day section used
  # to print that heading and an "Anteil 4/31" line four rows below it: two
  # sentences on one screen contradicting each other.
  def section_heading(section, index:, of:, detailed:)
    return 'Ein Abschnitt, ganzer Monat' unless detailed
    return "Ein Abschnitt   #{section_span(section)}" if of == 1

    "Abschnitt #{index + 1} von #{of}   #{section_span(section)}"
  end

  # Printed in Europe/Berlin, because that is the zone the month boundaries are
  # formed in (A6). A UTC timestamp next to a German calendar month is how an
  # operator ends up believing the peak happened two hours before it did.
  def moment(time)
    time.in_time_zone(Subscriptions::Constants::BILLING_TIME_ZONE).strftime('%d.%m.%Y %H:%M %Z')
  end

  # The §5 breakdown of ONE section.
  def print_section(section, index:, of:, detailed:)
    puts "  #{section_heading(section, index: index, of: of, detailed: detailed)}"
    puts format('    Hoechststand    %<peak>s', peak: I18n.t('admin.seat_peak.seats', count: section.peak))
    puts format('    erreicht am     %<at>s', at: moment(section.peak_at))
    if detailed
      puts format('    Anteil          %<num>d/%<den>d des Monats',
                  num: section.share.numerator, den: section.share.denominator)
    end

    section.organisations.each_with_index do |entry, position|
      label = position.zero? ? 'Organisationen' : ''
      puts format('    %<label>-15s %<name>-34s %<seats>d',
                  label: label, name: entry['organisation_name'].to_s[0, 34], seats: entry['seats'])
    end

    # The per-organisation figures sum to more than the peak whenever somebody
    # sits in two organisations. Stated, because otherwise the reader finds it
    # as a contradiction and the support call gets longer, not shorter.
    overlap = section.shared_seats
    puts "    Hinweis         #{I18n.t('admin.seat_peak.shared_seats_note', overlap: overlap)}" if overlap.positive?
  end
end

namespace :seat_peaks do
  desc 'Hoechststand je Konto fuer einen Messmonat — month[2026-08-01]'
  task :month, [:period_start] => :environment do |_task, args|
    abort 'Nutzung: rake "seat_peaks:month[2026-08-01]"' if args[:period_start].blank?

    period = SeatSnapshot.parse_period(args[:period_start])
    abort "seat_peaks:month — #{args[:period_start]} ist kein Datum." if period.nil?

    accounts = Account.order(:name).to_a
    puts "seat_peaks:month — Messmonat #{period} (Kalendermonat Europe/Berlin), #{accounts.size} Konto/Konten"

    # One evaluation per account: two queries each. Bounded by the account count
    # and run by hand, which is why it is not batched (see the Prosopite entry
    # for boundary_snapshot). A paginated screen over many accounts would be.
    accounts.each do |account|
      result = Subscriptions::SeatPeak.call(account: account, period_start: period)
      puts format('  %<name>-34s %<text>s',
                  name: account.name.to_s[0, 34], text: SeatPeakTaskOutput.status_text(result))
    end
  end

  desc 'Aufstellung eines Kontos (§5) — show[<account_id>,2026-08-01]'
  task :show, %i[account_id period_start] => :environment do |_task, args|
    abort 'Nutzung: rake "seat_peaks:show[<account_id>,2026-08-01]"' if args[:account_id].blank? || args[:period_start].blank?

    period = SeatSnapshot.parse_period(args[:period_start])
    abort "seat_peaks:show — #{args[:period_start]} ist kein Datum." if period.nil?

    account = Account.find_by(id: args[:account_id])
    abort "seat_peaks:show — kein Konto mit der Id #{args[:account_id]}." if account.nil?

    result = Subscriptions::SeatPeak.call(account: account, period_start: period)
    puts "seat_peaks:show — #{account.name}, Messmonat #{period}"

    # No answer is a complete answer here, and it ends the task without an error
    # code: asking about a month that has no snapshot yet is a normal thing to
    # do, unlike the drift check in seat_events:verify, where a finding means
    # nothing may be invoiced.
    unless result.ok?
      puts "  #{I18n.t("admin.seat_peak.reason.#{result.reason_key}")}"
      next
    end

    result.sections.each_with_index do |section, index|
      SeatPeakTaskOutput.print_section(section, index: index, of: result.sections.size,
                                                detailed: result.detailed?(section))
    end
    puts "  Hinweis           #{I18n.t('admin.seat_peak.provisional')}" if result.provisional?
  end
end
