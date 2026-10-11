# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: the operator task that moves an organisation between billing accounts
#       (K5 of doc/konto_ebene_plan.md).
# Type: Rake task spec.
# Why:  The service underneath is covered separately. What lives ONLY here is the
#       wiring, and every part of it can fail quietly:
#
#         * resolving two arguments by name. Moving the WRONG organisation is a
#           silent price change on two accounts nobody asked for, so an ambiguous
#           name has to refuse rather than pick.
#         * printing the price before and after. A move IS a price change, and
#           under R1 the invoice is written by hand from what this prints.
#         * saying out loud what K6 and K7 decided. Without those lines the usage
#           gap reads as a defect and the left-over account reads as a leak.
#         * exiting non-zero on a refusal, so a scripted run cannot swallow it.
RSpec.describe 'billing:move_org' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('billing:move_org')
  end

  before { Rake::Task['billing:move_org'].reenable }

  let(:source) { create(:account, name: 'Altes Konto') }
  let(:target) { create(:account, name: 'Neues Konto') }
  let(:organisation) { create(:organisation, account: source, name: 'Kundenfirma') }

  def add_counted_member(org)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: create(:user), organisation: org, active: true,
                          role: create(:role, organisation: org, billable: true))
    end
  end

  def add_guest(org, user)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, active: true,
                          role: create(:role, organisation: org, billable: false))
    end
  end

  # Runs the task with ENV set, captures stdout, and reports whether it exited
  # non-zero. `exit` raises SystemExit, so a plain invoke would abort the example.
  def run_task(env)
    original = ENV.to_h.slice('ORG', 'ACCOUNT', 'DRY_RUN', 'FORCE')
    env.each { |key, value| ENV[key.to_s] = value }
    %w[ORG ACCOUNT DRY_RUN FORCE].each { |key| ENV.delete(key) unless env.key?(key.to_sym) }

    failed = false
    output = capture_stdout do
      Rake::Task['billing:move_org'].invoke
    rescue SystemExit => e
      failed = !e.success?
    end
    [output, failed]
  ensure
    %w[ORG ACCOUNT DRY_RUN FORCE].each { |key| ENV.delete(key) }
    original.each { |key, value| ENV[key] = value }
  end

  def capture_stdout
    buffer = StringIO.new
    original = $stdout
    $stdout = buffer
    yield
    buffer.string
  ensure
    $stdout = original
  end

  describe 'resolving the arguments' do
    it 'accepts names, case-insensitively' do
      add_counted_member(organisation)
      target # both records have to EXIST before the task looks them up

      output, failed = run_task(ORG: 'kundenfirma', ACCOUNT: 'neues konto')

      expect(failed).to be(false)
      expect(organisation.reload.account).to eq(target)
      expect(output).to include('Kundenfirma')
    end

    it 'accepts UUIDs' do
      output, = run_task(ORG: organisation.id, ACCOUNT: target.id)

      expect(organisation.reload.account).to eq(target)
      expect(output).to include('Neues Konto')
    end

    # [CRITICAL] ACCOUNT names are NOT unique -- AccountAutoAssignable names each
    # new account after its organisation, and two customers can pick the same
    # company name in different tenants. Picking one of them would move billing to
    # the wrong customer, and nothing in the output would look wrong.
    #
    # Asked of the account rather than the organisation on purpose: organisation
    # names carry a global uniqueness validation, so that half of the shared
    # resolver can never reach this branch.
    it 'refuses an ambiguous account name and lists the candidates instead' do
      twin = create(:account, name: target.name)

      output, failed = run_task(ORG: organisation.id, ACCOUNT: target.name)

      expect(failed).to be(true)
      expect(output).to include('passt auf 2')
      expect(output).to include(target.id, twin.id)
      expect(organisation.reload.account).to eq(source)
    end

    it 'refuses an unknown name' do
      output, failed = run_task(ORG: 'gibtsnicht', ACCOUNT: target.id.to_s)

      expect(failed).to be(true)
      expect(output).to include('nicht gefunden')
    end

    it 'explains itself when an argument is missing' do
      output, failed = run_task(ORG: organisation.id)

      expect(failed).to be(true)
      expect(output).to include('ORG und ACCOUNT angeben')
    end
  end

  describe 'what it prints' do
    it 'shows seats and organisations for both accounts, and names the consequences' do
      add_counted_member(organisation)
      add_counted_member(create(:organisation, account: target, name: 'Schwester GmbH'))

      output, = run_task(ORG: organisation.id, ACCOUNT: target.id)

      # Bound to their BLOCK, not free-floating. Both numbers exist in the output
      # either way round, so swapping the two accounts produced exactly the same
      # two needles -- and the swapped preview is what an invoice would be
      # written from. Measured: with free needles, a before/after swap in
      # report_account left this file green.
      expect(output).to include("Aufnehmendes Konto: Neues Konto\n    Zugaenge: 1 -> 2")
      expect(output).to include("Abgebendes Konto: Altes Konto\n    Zugaenge: 1 -> 0")
      # The bundled list is what the customer sees on the billing page afterwards.
      expect(output).to include('Kundenfirma, Schwester GmbH')
      # K6 and K7, said at the moment they become true.
      expect(output).to include('bleiben beim abgebenden Konto')
      expect(output).to include('keine Organisation mehr')
    end

    # E4: an account nobody has decided to bill has no amount to state, and a
    # printed 0 EUR would assert something no one decided. Same three states as
    # the customer page. On production this is every account.
    it 'says "nicht vereinbart" instead of an amount while billing is undecided' do
      add_counted_member(organisation)

      output, = run_task(ORG: organisation.id, ACCOUNT: target.id)

      # `not_to include('0.00')` used to stand here and could not fail: without a
      # price list AmountPreview never reaches the formatted branch at all, so
      # the string does not exist in any variant of this page. What CAN break is
      # the wording landing on the wrong line, so the needle is bound to it.
      expect(output).to include('Betrag:   nicht vereinbart -> nicht vereinbart')
    end

    # [CRITICAL] The sentence the second review found to be false in its first
    # wording. Rolled-up consumption stays, everything after it follows the
    # organisation -- and the operator has to learn that BEFORE the move, because
    # the invoice is written by hand from this output.
    it 'names the period consumption is booked through, and what follows the organisation' do
      period = 2.months.ago.beginning_of_month.to_date
      create(:ai_usage_rollup, account: source, organisation: organisation, period_start: period)

      output, = run_task(ORG: organisation.id, ACCOUNT: target.id)

      expect(output).to include("aufgerollt bis einschliesslich #{period.strftime('%m/%Y')}")
      expect(output).to include('VOLLSTAENDIG auf das aufnehmende Konto')
    end

    it 'says so when nothing has been rolled up for this organisation yet' do
      output, = run_task(ORG: organisation.id, ACCOUNT: target.id)

      expect(output).to include('noch kein Verbrauch aufgerollt')
      expect(output).to include('gesamte bisherige')
    end

    # The consequence that carries no K-number and was therefore missing: the move
    # makes every active account_admin of the moving organisation a reader of the
    # target account, including the names of every other bundled organisation.
    it 'names who can newly read the target account' do
      output, = run_task(ORG: organisation.id, ACCOUNT: target.id)

      expect(output).to include('account_admins von "Kundenfirma"')
      expect(output).to include('Namen ALLER gebuendelten Organisationen')
    end

    # [CRITICAL] The only consequence of a move that reaches the CUSTOMER, and the
    # only one with a remedy. Bundling is what pushes a guest over
    # guest_max_organisations (default 1), and the org-admin then sees a flash
    # warning on their next membership write, about a limit they did not cross.
    it 'names the guest ceiling the bundling crosses, and the way out' do
      shared_guest = create(:user)
      add_guest(organisation, shared_guest)
      add_guest(create(:organisation, account: target, name: 'Schwester GmbH'), shared_guest)

      output, = run_task(ORG: organisation.id, ACCOUNT: target.id)

      # Bound to the receiving account's block, like the seat figures above: the
      # rule is "report it where the number ROSE", and a free-floating needle
      # would survive the line being printed under the wrong account.
      expect(output).to include('Aufnehmendes Konto: Neues Konto')
      expect(output).to include('Gastgrenze von "Neues Konto" ueberschritten: 0 -> 1')
      expect(output).to include('guest_max_organisations')
    end

    # The other half, and the reason the example above means something: the line
    # is conditional, not unconditional prose. The needle is proven to exist by
    # the example above, so its absence here is a statement about the condition
    # and not about a string nobody ever prints.
    it 'stays quiet about the ceiling when the bundling crosses nothing' do
      add_counted_member(organisation)
      add_counted_member(create(:organisation, account: target, name: 'Schwester GmbH'))

      output, = run_task(ORG: organisation.id, ACCOUNT: target.id)

      expect(output).to include("Aufnehmendes Konto: Neues Konto\n    Zugaenge: 1 -> 2")
      expect(output).not_to include('Gastgrenze')
    end

    it 'prints the real amount once the account is billed' do
      create(:price_list, :with_v4_monthly_ladder)
      target.update!(billing_starts_on: Date.current)
      add_counted_member(organisation)

      output, = run_task(ORG: organisation.id, ACCOUNT: target.id, FORCE: '1')

      # One seat lands on the 29 EUR rung. Pinned with the currency, not as the
      # bare digits: a rake output is short, but "29" alone would also match a
      # UUID fragment in the same text.
      expect(output).to include('29.00 EUR')
    end
  end

  describe 'DRY_RUN' do
    it 'prints the same figures but changes nothing' do
      add_counted_member(organisation)

      output, failed = run_task(ORG: organisation.id, ACCOUNT: target.id, DRY_RUN: '1')

      expect(failed).to be(false)
      # The figures a real run would produce: the empty target gains the one seat.
      # Bound to their BLOCK for the same reason as in the example above: both
      # strings occur either way round, so free needles survived a swap of the
      # two accounts, and the swapped preview is what an invoice gets written
      # from.
      expect(output).to include('DRY_RUN')
      expect(output).to include("Aufnehmendes Konto: Neues Konto\n    Zugaenge: 0 -> 1")
      expect(output).to include("Abgebendes Konto: Altes Konto\n    Zugaenge: 1 -> 0")
      expect(organisation.reload.account).to eq(source)
      expect(SeatEvent.where(event: Subscriptions::Constants::SEAT_EVENTS_FROM_OPERATOR)).to be_empty
    end
  end

  describe 'the refusal' do
    # [CRITICAL] Non-zero exit, not just a printed sentence. A scripted run that
    # ignores stdout must not treat a refused move as a completed one.
    it 'refuses a billed account, names the override, and exits non-zero' do
      source.update!(billing_starts_on: Date.current)

      output, failed = run_task(ORG: organisation.id, ACCOUNT: target.id)

      expect(failed).to be(true)
      expect(output).to include('ABGELEHNT')
      expect(output).to include('FORCE=1')
      expect(organisation.reload.account).to eq(source)
    end

    # §10.1: the same refusal reason, but a different sentence. For a monthly payer
    # the split is defined and FORCE is only a reminder; for the giving yearly
    # account it is not, there the same people are billed twice until the end of
    # the term. Both halves are pinned, because a shared sentence would wave
    # through exactly the more expensive case.
    it 'warns about the double payment when the giving account pays yearly' do
      source.update!(billing_starts_on: Date.current,
                     billing_interval: Subscriptions::Constants::INTERVAL_YEARLY)

      output, failed = run_task(ORG: organisation.id, ACCOUNT: target.id)

      expect(failed).to be(true)
      expect(output).to include('doppelt berechnet')
      expect(output).to include('Vertragsvorgang')
      # The casual FORCE hint of the monthly case must NOT appear here.
      expect(output).not_to include('FORCE=1 setzen und die Teilung')
    end

    # Only the GIVING account counts: if an organisation moves INTO a yearly account,
    # A4 bills the overage afterwards, and that is defined.
    it 'keeps the ordinary wording when only the receiving account pays yearly' do
      source.update!(billing_starts_on: Date.current)
      target.update!(billing_interval: Subscriptions::Constants::INTERVAL_YEARLY)

      output, = run_task(ORG: organisation.id, ACCOUNT: target.id)

      expect(output).to include('FORCE=1')
      expect(output).not_to include('doppelt berechnet')
    end

    # [CRITICAL] The refusal fires on an OR: it can come from the TARGET alone,
    # while the giving account has no start date at all and bills nothing
    # under E4. Then nobody pays twice, and the FORCE hint, which is right for
    # the split of the target, gets lost. The predicate read only the interval
    # and dropped the word "zahlend" (review finding on #536, reproduced
    # afterwards).
    it 'keeps the ordinary wording when the giving account is yearly but pays nothing' do
      source.update!(billing_starts_on: nil,
                     billing_interval: Subscriptions::Constants::INTERVAL_YEARLY)
      target.update!(billing_starts_on: Date.current)

      output, = run_task(ORG: organisation.id, ACCOUNT: target.id)

      expect(output).to include('FORCE=1')
      expect(output).not_to include('doppelt berechnet')
    end

    it 'goes through with FORCE' do
      source.update!(billing_starts_on: Date.current)

      _, failed = run_task(ORG: organisation.id, ACCOUNT: target.id, FORCE: '1')

      expect(failed).to be(false)
      expect(organisation.reload.account).to eq(target)
    end

    # Exits ZERO. A repeated run is the success case of an idempotent task, and a
    # script that reads the exit code (which is what the code is for, see the
    # example above) must not raise an alarm on it. The other refusal, which
    # needs a decision, still exits 1.
    it 'says nothing needs doing when the organisation is already there, without failing' do
      organisation.update!(account: target)

      output, failed = run_task(ORG: organisation.id, ACCOUNT: target.id)

      expect(failed).to be(false)
      expect(output).to include('Nichts zu tun')
    end
  end
end
