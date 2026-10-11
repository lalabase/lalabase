# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# What: the two operator tasks of the seat event stream (M0b,
#       doc/abrechnungsmodell_plan.md §3).
# Type: Rake task spec.
# Why:  Both carry a property that the services underneath cannot: the backfill
#       has to VERIFY itself afterwards, and the verification has to be loud.
#
#       A backfill that writes rows and says "done" while the stream still
#       disagrees with SeatCounter is the exact shape of the production finding
#       that started this slice, and a verify task that merely prints its
#       findings would be swallowed by a nightly run. Neither is visible from
#       the service specs, because both live in the wiring.
RSpec.describe 'seat_events tasks' do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('seat_events:verify')
  end

  before do
    Rake::Task['seat_events:backfill_openings'].reenable
    Rake::Task['seat_events:verify'].reenable
  end

  let(:organisation) { create(:organisation) }

  def add_counted_member(org)
    user = create(:user)
    ActsAsTenant.with_tenant(org) do
      create(:membership, user: user, organisation: org, active: true,
                          role: create(:role, organisation: org, billable: true))
    end
    user
  end

  describe 'seat_events:verify' do
    it 'passes quietly when stream and counter agree' do
      expect { Rake::Task['seat_events:verify'].invoke }
        .to output(/stimmen fuer jedes Konto ueberein/).to_stdout
    end

    # The load-bearing half. §3: as long as the two disagree, no figure from the
    # stream may reach an invoice. A task that printed and exited 0 would let a
    # scheduled run report success over a broken ledger.
    it 'aborts, and does not merely print, when they disagree' do
      add_counted_member(organisation)
      SeatEvent.delete_all # the state the stream was actually in on production

      expect { Rake::Task['seat_events:verify'].invoke }
        .to raise_error(SystemExit)
        .and output(/live=1, Strom hat fuer diesen Zeitpunkt keine Grundlage/).to_stdout
    end
  end

  describe 'seat_events:backfill_openings' do
    it 'writes the openings and then verifies itself' do
      add_counted_member(organisation)
      SeatEvent.delete_all

      expect { Rake::Task['seat_events:backfill_openings'].invoke }
        .to change { SeatEvent.where(event: Subscriptions::Constants::SEAT_EVENT_OPENING).count }
        .from(0).to(1)
        .and output(/1 Eroeffnungen geschrieben.*stimmen fuer jedes Konto ueberein/m).to_stdout
    end

    # The obvious operator sequence: look first, then fix. Rake::Task#invoke is a
    # NO-OP once the task ran in this process, so without an explicit reenable the
    # backfill silently skips its own verification in exactly the order a careful
    # operator would use. The `before` hook of this file reenables both tasks, and
    # that is precisely why the other examples cannot see this: the example has to
    # run verify itself to recreate the condition.
    it 'verifies itself even when verify already ran in the same process' do
      # A PASSING verify first, so the task is marked as run without an abort.
      # Aborting here would raise SystemExit, and an uncaught one kills the whole
      # rspec process instead of failing this example -- which is exactly what
      # made the first version of this probe useless.
      expect { Rake::Task['seat_events:verify'].invoke }.to output(/ueberein/).to_stdout

      add_counted_member(organisation)
      SeatEvent.delete_all

      expect { Rake::Task['seat_events:backfill_openings'].invoke }
        .to output(/stimmen fuer jedes Konto ueberein/).to_stdout
    end

    # Without this the operator has no way to look before leaping, and the first
    # run against production would be the first time anyone sees the numbers.
    it 'writes nothing on DRY_RUN and does not run the verification' do
      add_counted_member(organisation)
      SeatEvent.delete_all

      expect { with_env('DRY_RUN' => '1') { Rake::Task['seat_events:backfill_openings'].invoke } }
        .to output(/DRY_RUN.*waeren zu schreiben/m).to_stdout
      expect(SeatEvent.count).to eq(0)
    end
  end

  def with_env(vars)
    previous = vars.transform_values { |_| nil }.merge(ENV.slice(*vars.keys))
    ENV.update(vars)
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
