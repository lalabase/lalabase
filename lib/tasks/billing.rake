# frozen_string_literal: true

# Operator entry point for the agency case (K5 of doc/konto_ebene_plan.md):
# several organisations under ONE billing account, one invoice.
#
# No UI on purpose (§2, user-approved): the assignment is rare, and whoever needs
# it calls. What this task adds over a console `update!` is the part a console
# does not have -- the seat-stream transitions, the refusals, and the price
# before/after. The logic lives in Subscriptions::OrganisationMove; this file
# resolves the two arguments and prints.
namespace :billing do
  desc 'Organisation in ein anderes Rechnungskonto verschieben. Immer zuerst mit DRY_RUN=1. ' \
       'ORG=<uuid|name> ACCOUNT=<uuid|name> [DRY_RUN=1] [FORCE=1]'
  task move_org: :environment do
    org_identifier = ENV.fetch('ORG', nil)
    account_identifier = ENV.fetch('ACCOUNT', nil)

    unless org_identifier && account_identifier
      puts 'FEHLER: ORG und ACCOUNT angeben. Beispiele:'
      puts '  ORG=acme ACCOUNT="gboyke solutions" DRY_RUN=1 rake billing:move_org'
      puts '  ORG=<org-uuid> ACCOUNT=<account-uuid> rake billing:move_org'
      exit 1
    end

    # without_tenant because the task runs with none set and acts_as_tenant is
    # configured to REQUIRE one. Organisation itself carries no acts_as_tenant --
    # it IS the tenant -- so this is about the global requirement, not about
    # widening a scope. Nothing tenant-bound is read unfiltered here: every role
    # join below runs under with_tenant (see Subscriptions::OrganisationMove).
    organisation, account = ActsAsTenant.without_tenant do
      [BillingMoveOrgTask.resolve_organisation(org_identifier),
       BillingMoveOrgTask.resolve_account(account_identifier)]
    end
    exit 1 unless organisation && account

    dry_run = ENV['DRY_RUN'] == '1'
    result = ActsAsTenant.without_tenant do
      Subscriptions::OrganisationMove.call(
        organisation: organisation, account: account,
        dry_run: dry_run, force: ENV['FORCE'] == '1'
      )
    end

    BillingMoveOrgTask.report(result)

    # Only the refusal that needs a DECISION exits non-zero. "already in that
    # account" is the success case of a repeated run, and failing there would
    # make the task non-idempotent for every script that reads the exit code --
    # which is exactly what the code is for.
    exit 1 if result.refused == Subscriptions::OrganisationMove::REFUSAL_BILLING_STARTED
  end
end

# Printing and argument resolution, kept out of the task body so it is testable
# without invoking rake. NOT under app/services: this is the presentation of one
# operator task, and a service object would suggest a second caller that must not
# exist (the whole point of K5 is that there is no UI).
module BillingMoveOrgTask
  module_function

  # Id first, then name (case-insensitively). An ambiguous name is a refusal
  # rather than a lucky pick: moving the WRONG organisation is a silent price
  # change on two accounts that nobody asked for.
  #
  # No slug lookup, unlike notifications_verify.rake: `organisations` has no such
  # column, so that branch there raises PG::UndefinedColumn the moment somebody
  # passes a non-uuid.
  def resolve_organisation(identifier)
    by_id = Organisation.find_by(id: identifier)
    return by_id if by_id

    matches = Organisation.where('LOWER(name) = ?', identifier.to_s.downcase).to_a
    resolve_unique(matches, identifier, 'Organisation')
  end

  def resolve_account(identifier)
    by_id = Account.find_by(id: identifier)
    return by_id if by_id

    matches = Account.where('LOWER(name) = ?', identifier.to_s.downcase).to_a
    resolve_unique(matches, identifier, 'Konto')
  end

  def resolve_unique(matches, identifier, label)
    case matches.size
    when 1 then matches.first
    when 0
      puts "FEHLER: #{label} nicht gefunden fuer '#{identifier}'."
      nil
    else
      puts "FEHLER: '#{identifier}' passt auf #{matches.size} #{label}-Eintraege. Bitte die UUID angeben:"
      matches.each { |match| puts "  #{match.id}  #{match.name}" }
      nil
    end
  end

  def report(result)
    return report_refusal(result) if result.refused?

    puts format('billing:move_org%<mode>s', mode: result.dry_run ? ' (DRY_RUN, nichts geschrieben)' : '')
    puts format('  Organisation: %<name>s', name: result.organisation.name)
    puts format('  von Konto:    %<name>s', name: result.source_account&.name || '(keines)')
    puts format('  nach Konto:   %<name>s', name: result.target_account.name)
    puts ''
    report_account('Abgebendes Konto', result.source_account, result.source_before, result.source_after)
    report_account('Aufnehmendes Konto', result.target_account, result.target_before, result.target_after)
    puts ''
    puts format('  %<n>d gezaehlte Mitgliedschaft(en), %<e>d Seat-Ereignis(se)%<verb>s',
                n: result.memberships_moved, e: result.events_written,
                verb: result.dry_run ? ' waeren zu schreiben' : ' geschrieben')
    report_consequences(result)
  end

  # Two accounts, same shape. Seats and amount, before and after, because a move
  # IS a price change and it has to be visible before it happens.
  # `after` is never nil once `account` is present -- both snapshots are taken
  # for the same account. The earlier `after&.seats || 0` contradicted the reason
  # Snapshot returns nil in the first place (nil means "nothing to measure", 0 is
  # a measurement), and it was unreachable on top of that.
  def report_account(label, account, before, after)
    return if account.nil?

    puts format('  %<label>s: %<name>s', label: label, name: account.name)
    puts format('    Zugaenge: %<before>d -> %<after>d', before: before.seats, after: after.seats)
    puts format('    Betrag:   %<before>s -> %<after>s',
                before: amount_line(before.amount), after: amount_line(after.amount))
    puts format('    Orgs:     %<orgs>s', orgs: after.organisation_names.join(', ').presence || '(keine)')
    report_guest_ceiling(account, before, after)
  end

  # Only when the number ROSE, and that is the whole rule -- applied to both
  # accounts rather than to the receiving one by name. Violations that already
  # existed are not this move's doing, and reporting them here would train the
  # operator to skip the line.
  #
  # Reaches the customer, unlike everything else on this page: the org-admin of
  # the moved organisation gets a flash warning on their next membership write
  # (Organisations::BaseController#warn_if_guest_ceiling_exceeded). Hence the
  # remedy in the same sentence -- this is the one consequence the operator can
  # actually act on.
  def report_guest_ceiling(account, before, after)
    return unless after.guest_violations > before.guest_violations

    puts format('  ACHTUNG: Gastgrenze von "%<name>s" ueberschritten: %<before>d -> %<after>d ' \
                'betroffene Gaeste bei einem Limit von %<limit>d Organisation(en). Das Buendeln ist ' \
                'die Ursache - dieselben Gaeste waren vorher auf zwei Konten verteilt. Der Kunde sieht ' \
                'den Hinweis beim naechsten Mitgliedschafts-Write. Abhilfe: guest_max_organisations ' \
                'an diesem Konto hochsetzen.',
                name: account.name, before: before.guest_violations,
                after: after.guest_violations, limit: after.guest_organisation_limit)
  end

  # Never a bare number. An account without a decided billing_starts_on has no
  # amount to state (E4), and printing 0 EUR there would assert something nobody
  # decided. Same three states as the customer page, in the same order.
  def amount_line(amount)
    return '(kein Konto)' if amount.nil?
    return 'nicht vereinbart' if amount.billing_start_undecided?
    return 'niemand berechnet' if amount.no_billable_seats?
    return 'Preis offen' if amount.price_missing?

    format('%<euro>.2f %<currency>s', euro: amount.total_cents / 100.0, currency: amount.currency)
  end

  # What the move drags along, said out loud at the moment it becomes true.
  # Without these lines the usage seam looks like a defect, the left-over account
  # looks like a leak, and the new reader on the target account looks like a bug.
  def report_consequences(result)
    report_usage_seam(result)
    report_visibility(result)
    return unless result.source_emptied

    puts format('  Hinweis: Das Konto "%<name>s" hat jetzt keine Organisation mehr. Es bleibt bestehen (K7) ' \
                '- Loeschen wuerde Rabatte und Antraege mitnehmen.', name: result.source_account.name)
  end

  # The honest version of K6, and it took a second review to get here. Rows that
  # EXIST keep their account. Everything not yet rolled up is booked in full to
  # the new account by the next monthly run, including the days before the move,
  # because AiUsageAggregator reads organisation.account_id at aggregation time
  # and ai_usage_rollups holds one row per organisation and month.
  def report_usage_seam(result)
    puts '  Hinweis: Seat-Historie und bereits aufgerollter Verbrauch bleiben beim abgebenden Konto (K6).'
    through = result.usage_rolled_up_through

    if through
      puts format('  ACHTUNG: Verbrauch ist aufgerollt bis einschliesslich %<month>s. Alles danach, auch der ' \
                  'laufende Monat, bucht der naechste Monatslauf VOLLSTAENDIG auf das aufnehmende Konto - ' \
                  'ein Monat laesst sich nicht teilen.', month: through.strftime('%m/%Y'))
    else
      puts '  ACHTUNG: Fuer diese Organisation ist noch kein Verbrauch aufgerollt. Der gesamte bisherige ' \
           'Verbrauch bucht damit auf das aufnehmende Konto.'
    end
    puts '  Am saubersten ist ein Umzug direkt nach dem Monatslauf, solange der neue Monat noch leer ist.'
  end

  # Not a K-number, and that is why it was missing: the move makes every active
  # account_admin of the moving organisation an eligible reader of the TARGET
  # account (AccountPolicy#show_overview? via Account#eligible_owner?). They then
  # see the names of every other bundled organisation and the total. In the
  # agency case that means the admin of customer A learns that customer B is
  # billed here too. Named at the first move, not first at the merge.
  def report_visibility(result)
    puts format('  Hinweis: Aktive account_admins von "%<org>s" sehen ab jetzt das Konto "%<acc>s", ' \
                'darin die Namen ALLER gebuendelten Organisationen und den Gesamtbetrag.',
                org: result.organisation.name, acc: result.target_account.name)
  end

  # Only the GIVING account counts, and only if it actually PAYS. Two
  # restrictions, both needed:
  #
  # If an organisation moves INTO a yearly account, its monthly peak rises
  # and A4 bills the excess afterwards. Defined, not a double case.
  #
  # And the refusal fires on an OR: it can come from the TARGET alone,
  # while the giving account has no start date and bills nothing under
  # E4. Without billing_start_decided? the heavier message wins there,
  # although nobody pays twice, and the FORCE hint, which is right for the
  # split of the target, drops out. Exactly the word "paying" ("zahlend") that the
  # plan and the comment in organisation_move.rb use was missing here
  # (review finding for #536, added afterwards).
  #
  # This is NOT a second interval check in the write path: the refusal
  # itself stays unchanged, this only decides which sentence is
  # printed.
  def paying_yearly_source?(result)
    account = result.source_account
    account&.billing_start_decided? &&
      account.billing_interval == Subscriptions::Constants::INTERVAL_YEARLY
  end

  def report_refusal(result)
    case result.refused
    when Subscriptions::OrganisationMove::REFUSAL_SAME_ACCOUNT
      puts format('Nichts zu tun: "%<org>s" gehoert bereits zum Konto "%<acc>s".',
                  org: result.organisation.name, acc: result.target_account.name)
    when Subscriptions::OrganisationMove::REFUSAL_BILLING_STARTED
      puts 'ABGELEHNT: Bei einem der beiden Konten ist die Abrechnung bereits vereinbart ' \
           '(billing_starts_on gesetzt).'
      puts '  Ein Umzug teilt dann den laufenden Zeitraum, und die Rechnung entsteht unter R1 von Hand.'
      # §10.1: for a yearly payer FORCE means something different, and the difference
      # belongs in the output. For a monthly payer the split is defined (A3),
      # you only have to account for it by hand. For the giving yearly account
      # it is NOT: it keeps paying its committed tier until the end of the year
      # (A4), while the receiving account pays its segment.
      # The same sentence for both cases would be an invitation to wave the
      # more expensive one through.
      if paying_yearly_source?(result)
        puts '  ACHTUNG, abgebendes Konto zahlt JAEHRLICH: Es zahlt seine zugesagte Stufe bis'
        puts '  zum Jahresende weiter (A4), das aufnehmende Konto zahlt seinen Abschnitt (A3).'
        puts '  Dieselben Menschen werden bis zum Laufzeitende doppelt berechnet. Das ist ein'
        puts '  Vertragsvorgang, kein Betriebsvorgang: erst die Zusage klaeren, dann umziehen.'
      else
        puts '  Wenn das gewollt ist: FORCE=1 setzen und die Teilung auf der Rechnung beruecksichtigen.'
      end
    else
      # A refusal nobody worded would print nothing and still stop the move. The
      # symbols exist BECAUSE each case needs its own explanation; this makes
      # that contract fail loudly instead of silently.
      raise "billing:move_org: unbeschriebene Verweigerung #{result.refused.inspect}"
    end
  end
end
