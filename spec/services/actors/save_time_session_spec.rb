# frozen_string_literal: true

# spec/services/actors/save_time_session_spec.rb
#
# What: unit spec for the SaveTimeSession actor (create + update incl. the
#   billing-group transition in one transaction).
# Why: pins the group_change tri-state contract (absent key = no group change,
#   [P1] twin of T2's :billed key; blank = explicit removal; group = assign),
#   both billed guards as coded failures (:group_billed / :session_billed —
#   the :session_billed side sits BEHIND TimeSessionPolicy#update?, which
#   already denies billed sessions over HTTP, so it is only reachable here:
#   defense-in-depth for non-HTTP callers), and the all-or-nothing atomicity
#   of attribute + group writes (plan doc/actors_t3_save_time_session_plan.md).

require 'rails_helper'

RSpec.describe Actors::SaveTimeSession, type: :service do
  let(:organisation) { create(:organisation) }
  let(:user) { create(:user) }
  let(:project) { create(:project, organisation: organisation) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: user, organisation: organisation)
  end

  def call_actor(time_session, attributes: {}, group_change: { requested: false, group: nil })
    described_class.call(time_session: time_session, attributes: attributes,
                         group_change: group_change, current_user: user)
  end

  def build_session(**attrs)
    build(:time_session, { organisation: organisation, project: project,
                           creator: user, duration: 30 }.merge(attrs))
  end

  def create_session(**attrs)
    create(:time_session, { organisation: organisation, project: project,
                            creator: user, duration: 60 }.merge(attrs))
  end

  describe 'create' do
    it 'saves a new record and assigns the requested unbilled group without billing it' do
      group = create(:time_session_group, organisation: organisation, creator: user)
      session = build_session

      result = call_actor(session, group_change: { requested: true, group: group })

      expect(result).to be_success
      expect(result.resource).to eq(session)
      expect(session.reload.time_session_group).to eq(group)
      expect(session.billed).to be(false)
    end

    it 'refuses a billed target group with :group_billed and persists nothing' do
      group = create(:time_session_group, :billed, organisation: organisation, creator: user)
      session = build_session

      result = call_actor(session, group_change: { requested: true, group: group })

      expect(result).not_to be_success
      expect(result.code).to eq(:group_billed)
      expect(result.errors).to eq([I18n.t('services.save_time_session.group_billed')])
      expect(session).not_to be_persisted
    end
  end

  describe 'update group transitions' do
    it 'treats an absent key as "no group change" ([P1] twin)' do
      group = create(:time_session_group, organisation: organisation, creator: user)
      session = create_session(time_session_group: group)

      result = call_actor(session, attributes: { description: 'Nur Text' },
                                   group_change: { requested: false, group: nil })

      expect(result).to be_success
      session.reload
      expect(session.time_session_group).to eq(group)
      expect(session.description).to eq('Nur Text')
    end

    it 'removes the group on an explicit nil target' do
      group = create(:time_session_group, organisation: organisation, creator: user)
      session = create_session(time_session_group: group)

      result = call_actor(session, group_change: { requested: true, group: nil })

      expect(result).to be_success
      expect(session.reload.time_session_group).to be_nil
    end

    it 'refuses to change the group of a billed session with :session_billed' do
      group = create(:time_session_group, :billed, organisation: organisation, creator: user)
      session = create_session(time_session_group: group, billed: true,
                               billed_at: group.billed_at, invoice_number: group.invoice_number)

      result = call_actor(session, group_change: { requested: true, group: nil })

      expect(result).not_to be_success
      expect(result.code).to eq(:session_billed)
      expect(result.errors).to eq([I18n.t('services.save_time_session.session_billed')])
      expect(session.reload.time_session_group).to eq(group)
    end

    it 'treats a target equal to the current group as no transition (no billed guard)' do
      group = create(:time_session_group, :billed, organisation: organisation, creator: user)
      session = create_session(time_session_group: group, billed: true,
                               billed_at: group.billed_at, invoice_number: group.invoice_number)

      # Same group re-submitted, no other change: parity with the previous
      # old != new controller check — must not trip :group_billed.
      result = call_actor(session, group_change: { requested: true, group: group })

      expect(result).to be_success
      expect(session.reload.time_session_group).to eq(group)
    end
  end

  describe 'atomicity' do
    it 'rolls the group transition back when an attribute fails validation' do
      group = create(:time_session_group, organisation: organisation, creator: user)
      session = create_session

      result = call_actor(session, attributes: { occurred_on: nil },
                                   group_change: { requested: true, group: group })

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(session.reload.time_session_group).to be_nil
    end
  end

  describe 'race parity (stale instances)' do
    it 'rejects a group that was billed after it was loaded' do
      group = create(:time_session_group, organisation: organisation, creator: user)
      session = build_session
      # Simulate a concurrent invoicing behind the caller's back: the in-memory
      # group still says unbilled, the row is billed.
      group.class.where(id: group.id).update_all(billed: true)

      result = call_actor(session, group_change: { requested: true, group: group })

      expect(result).not_to be_success
      expect(result.code).to eq(:group_billed)
    end

    it 'surfaces a concurrently billed session as a validation failure instead of overwriting it' do
      session = create_session(description: 'Original')
      session.class.where(id: session.id).update_all(billed: true)

      result = call_actor(session, attributes: { description: 'Überschrieben' })

      expect(result).not_to be_success
      expect(result.code).to eq(:validation_failed)
      expect(session.reload.description).to eq('Original')
    end
  end
end
