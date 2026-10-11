# frozen_string_literal: true

# spec/services/actors/update_time_session_group_billing_spec.rb
#
# What: unit spec for the UpdateTimeSessionGroupBilling actor (group update
#   including the billing-status transition).
# Why: pins the [P1] fix semantics (absent/blank :billed key = NO billing
#   change, plan §9.8-4), the all-or-nothing atomicity of transition +
#   remaining fields (plan §9.3-3), and the no-transition full-update parity
#   (invoice edits on billed groups stay allowed).

require 'rails_helper'

RSpec.describe Actors::UpdateTimeSessionGroupBilling, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }
  let(:group) { create(:time_session_group, organisation: organisation, creator: user, name: 'Sprint Mai') }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  def call_actor(target, params)
    described_class.call(group: target, params: params, current_user: user)
  end

  def session_in(target, **attrs)
    create(:time_session,
           { organisation: organisation, project: project, creator: user,
             time_session_group: target }.merge(attrs))
  end

  describe 'transition unbilled -> billed' do
    it 'bills group + sessions and saves the remaining fields in one go' do
      session = session_in(group)

      result = call_actor(group, { name: 'Sprint Juni', billed: '1', invoice_number: 'INV-77' })

      expect(result).to be_success
      expect(result.resource).to eq(group)
      group.reload
      expect(group.billed).to be(true)
      expect(group.invoice_number).to eq('INV-77')
      expect(group.name).to eq('Sprint Juni')
      session.reload
      expect(session.billed).to be(true)
      expect(session.invoice_number).to eq('INV-77')
    end

    # F3 pin: a blank billed_at from the form falls back to Time.current
    # (.presence) and the model callback normalizes it to the beginning of day —
    # same end result as the previous set_billed_at path.
    it 'defaults a blank billed_at to today' do
      result = call_actor(group, { billed: '1', invoice_number: 'INV-78', billed_at: '' })

      expect(result).to be_success
      expect(group.reload.billed_at).to eq(Date.current.beginning_of_day)
    end

    # Pins the .presence pass-through branch: an explicitly chosen (retroactive)
    # invoice date must reach the billing service — a regression stamping every
    # invoice with "today" would otherwise survive the suite, because all other
    # examples only exercise the blank-fallback branch.
    it 'passes an explicitly submitted billed_at through to the transition' do
      result = call_actor(group, { billed: '1', invoice_number: 'INV-80', billed_at: '2026-06-01' })

      expect(result).to be_success
      expect(group.reload.billed_at).to eq(Date.new(2026, 6, 1).beginning_of_day)
    end
  end

  describe 'transition billed -> unbilled' do
    let(:billed_group) { create(:time_session_group, :billed, organisation: organisation, creator: user) }

    it 'clears the invoice data on group + sessions for an explicit billed: 0' do
      session = session_in(billed_group, billed: true, invoice_number: billed_group.invoice_number)

      result = call_actor(billed_group, { billed: '0' })

      expect(result).to be_success
      billed_group.reload
      expect(billed_group.billed).to be(false)
      expect(billed_group.invoice_number).to be_nil
      expect(billed_group.billed_at).to be_nil
      session.reload
      expect(session.billed).to be(false)
      expect(session.invoice_number).to be_nil
    end
  end

  describe 'atomicity (plan §9.3-3)' do
    it 'rolls the billing transition back when a remaining field is invalid' do
      session = session_in(group)

      result = call_actor(group, { billed: '1', invoice_number: 'INV-79', name: '' })

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      group.reload
      expect(group.billed).to be(false)
      expect(group.invoice_number).to be_nil
      expect(group.name).to eq('Sprint Mai')
      expect(session.reload.billed).to be(false)
    end

    it 'maps a missing invoice_number on mark-billed to :validation_failed and rolls back' do
      session = session_in(group)

      result = call_actor(group, { billed: '1' })

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(group.reload.billed).to be(false)
      expect(session.reload.billed).to be(false)
    end

    # Mirror of the unbilled -> billed case above: the billed -> unbilled
    # transition must be all-or-nothing too. mark_as_unbilled succeeds first,
    # then the remaining-field update! raises — the outer BaseActor transaction
    # must roll the whole unbilling back (no silent partial success: group AND
    # sessions keep their billed state including the invoice data).
    it 'rolls the unbilling back when a remaining field is invalid (billed -> unbilled)' do
      billed_group = create(:time_session_group, :billed, organisation: organisation, creator: user)
      invoice_number = billed_group.invoice_number
      session = session_in(billed_group, billed: true, invoice_number: invoice_number)

      result = call_actor(billed_group, { billed: '0', name: '' })

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      billed_group.reload
      expect(billed_group.billed).to be(true)
      expect(billed_group.invoice_number).to eq(invoice_number)
      expect(billed_group.billed_at).to be_present
      session.reload
      expect(session.billed).to be(true)
      expect(session.invoice_number).to eq(invoice_number)
    end
  end

  # Mutation-killer for the .reload in #perform (plan §9.8-1, parity with the
  # generate actor's race spec): the defense only shows when the actor holds a
  # STALE unbilled instance while the DB row was invoiced concurrently. Without
  # the reload, the no-transition path (no :billed key) blanks the invoice
  # number on the billed row — the presence validation still checks the stale
  # in-memory billed? == false — recreating the [P1] corruption class.
  describe 'reload race defense (plan §9.8-1)' do
    it 'rejects blanking the invoice data of a group invoiced concurrently behind a stale instance' do
      # Flip the DB row BEHIND the actor's instance: update_columns on a
      # separately loaded copy keeps `group` unbilled in-memory.
      TimeSessionGroup.find(group.id)
                      .update_columns(billed: true, invoice_number: 'INV-RACE', billed_at: Time.current)
      expect(group).not_to be_billed # race precondition: instance is stale

      result = call_actor(group, { name: 'Umbenannt', invoice_number: '' })

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      group.reload
      expect(group.billed).to be(true)
      expect(group.invoice_number).to eq('INV-RACE')
      expect(group.name).to eq('Sprint Mai')
    end
  end

  describe '[P1] billing semantics matrix (plan §9.8-4)' do
    context 'on a billed group' do
      let(:billed_group) { create(:time_session_group, :billed, organisation: organisation, creator: user) }
      let!(:session) { session_in(billed_group, billed: true, invoice_number: billed_group.invoice_number) }

      it 'treats an ABSENT :billed key as "no billing change"' do
        result = call_actor(billed_group, { name: 'Umbenannt' })

        expect(result).to be_success
        billed_group.reload
        expect(billed_group.billed).to be(true)
        expect(billed_group.invoice_number).to be_present
        expect(billed_group.name).to eq('Umbenannt')
        expect(session.reload.billed).to be(true)
      end

      it 'treats billed: nil as "no billing change"' do
        result = call_actor(billed_group, { billed: nil, name: 'Umbenannt' })

        expect(result).to be_success
        expect(billed_group.reload.billed).to be(true)
        expect(session.reload.invoice_number).to be_present
      end

      it 'treats billed: "" as "no billing change" (casts to nil)' do
        result = call_actor(billed_group, { billed: '', name: 'Umbenannt' })

        expect(result).to be_success
        expect(billed_group.reload.billed).to be(true)
        expect(session.reload.invoice_number).to be_present
      end

      it 'takes the full-update path for billed: "1" on an already billed group (invoice correction)' do
        result = call_actor(billed_group, { billed: '1', invoice_number: 'INV-NEU' })

        expect(result).to be_success
        billed_group.reload
        expect(billed_group.billed).to be(true)
        expect(billed_group.invoice_number).to eq('INV-NEU')
      end
    end

    context 'on an unbilled group' do
      it 'treats billed: "0" as "no billing change" (already unbilled)' do
        result = call_actor(group, { billed: '0', name: 'Sprint Juni' })

        expect(result).to be_success
        group.reload
        expect(group.billed).to be(false)
        expect(group.name).to eq('Sprint Juni')
      end
    end
  end
end
