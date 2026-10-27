# frozen_string_literal: true

require 'rails_helper'

# Which participants the link dialog leaves alone, because their link runs
# through an account (S2b). The actor and the participant row both ask this.
RSpec.describe Meetings::AccountParticipants, :ci_guard do
  let(:organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  let(:meeting) { create(:meeting, organisation: organisation, project: create(:project, organisation: organisation)) }

  def member(active: true)
    create(:user).tap do |user|
      create(:membership, user: user, organisation: organisation, role: create(:role, organisation: organisation),
                          active: active)
    end
  end

  def participant(name, **keys)
    create(:meeting_participant, meeting: meeting, display_name: name, **keys)
  end

  def through_account?(record)
    described_class.new(organisation: organisation, participants: meeting.meeting_participants.reload.to_a).include?(record)
  end

  it 'counts a member, active or deactivated' do
    expect(through_account?(participant('Aktiv', user: member))).to be(true)
    expect(through_account?(participant('Pausiert', user: member(active: false)))).to be(true)
  end

  it 'does not count someone whose membership here was removed, even with one elsewhere' do
    gone = create(:user)
    elsewhere = create(:organisation)
    ActsAsTenant.with_tenant(elsewhere) do
      create(:membership, user: gone, organisation: elsewhere, role: create(:role, organisation: elsewhere))
    end

    expect(through_account?(participant('Weg', user: gone))).to be(false)
  end

  it 'does not count a free name or a contact without an account' do
    expect(through_account?(participant('Frei'))).to be(false)
    expect(through_account?(participant('Kontakt', person: create(:person, organisation: organisation)))).to be(false)
  end

  it 'counts a contact whose row belongs to an active member now' do
    row = create(:person, organisation: organisation, name: 'Jonas Weber')
    linked = participant('J. Weber', person: row)
    row.update!(user: member)

    expect(through_account?(linked)).to be(true)
  end

  it 'does not count a contact whose row belongs to a deactivated member' do
    row = create(:person, organisation: organisation, name: 'Fritz Frueher', user: member)
    Membership.where(user_id: row.user_id).update_all(active: false)

    expect(through_account?(participant('Fritz', person: row))).to be(false)
  end

  # The participant row asks for every chip: one lookup per key, not per chip.
  it 'asks the database twice, however many participants' do
    Prosopite.pause do
      3.times { |i| participant("Mitglied #{i}", user: member) }
      3.times { |i| participant("Kontakt #{i}", person: create(:person, organisation: organisation)) }
    end
    records = meeting.meeting_participants.to_a
    accounts = described_class.new(organisation: organisation, participants: records)

    queries = 0
    count = ->(*, payload) { queries += 1 unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(count, 'sql.active_record') do
      records.each { |record| accounts.include?(record) }
    end

    expect(queries).to eq(2)
  end
end
