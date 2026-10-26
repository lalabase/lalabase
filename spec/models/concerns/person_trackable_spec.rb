# frozen_string_literal: true

require 'rails_helper'

# A person row holds data about third parties, and its activities outlive it.
# So no activity names the person or carries a value, nothing fans out, and a
# delete leaves exactly one anonymous row (D6).
RSpec.describe PersonTrackable, type: :model do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user, organisation: organisation) }

  before do
    ActiveJob::Base.queue_adapter = :test
    ActsAsTenant.current_tenant = organisation
    Current.user = writer
  end

  after do
    Current.user = nil
    ActsAsTenant.current_tenant = nil
  end

  let(:secret_values) { ['Erika Geheim', '+49 30 9876543', 'erika.geheim@example.com', 'Nur fuer uns'] }

  def create_person
    create(:person, organisation: organisation, name: 'Erika Geheim', phone: '+49 30 9876543',
                    email: 'erika.geheim@example.com', notes: 'Nur fuer uns')
  end

  def serialized(activities)
    activities.map { |a| [a.parameters, a.attribute_changes].to_json }.join
  end

  def expect_no_personal_data(activities)
    text = serialized(activities)
    secret_values.each { |value| expect(text).not_to include(value) }
  end

  it 'writes a created activity without a name' do
    person = create_person

    activity = Activity.find_by!(trackable: person, action: 'created')
    expect(activity.key).to eq('person.created')
    expect_no_personal_data([activity])
  end

  it 'keeps only the names of changed fields on update, no values' do
    person = create_person
    person.update!(phone: '+49 40 1111111', notes: 'Neu', name: 'Erika Neu')

    activity = Activity.find_by!(trackable: person, action: 'updated')
    expect(activity.attribute_changes.keys).to contain_exactly('phone', 'notes', 'name')
    expect(activity.attribute_changes.values).to all(be_nil)
    expect(serialized([activity])).not_to include('+49 40 1111111', 'Erika Neu')
  end

  it 'does not record bookkeeping columns as changes' do
    person = create_person
    person.update!(phone: '1')

    keys = Activity.find_by!(trackable: person, action: 'updated').attribute_changes.keys
    expect(keys).not_to include('lock_version', 'normalized_name', 'updater_id', 'updated_at')
  end

  it 'leaves exactly one anonymous deleted activity behind' do
    person = create_person
    person.update!(phone: '1')
    person.destroy!

    remaining = Activity.where(trackable_type: 'Person', trackable_id: person.id)
    expect(remaining.map(&:action)).to eq(['deleted'])
    expect(remaining.first.actor).to eq(writer)
    expect_no_personal_data(remaining)
  end

  it 'creates no outbox event and no notification on create, update or destroy' do
    expect do
      person = create_person
      person.update!(phone: '1')
      person.destroy!
    end.not_to(change { [OutboxEvent.count, Notification.count] })
  end

  it 'keeps the quiet context even when a caller sets its own' do
    person = build(:person, organisation: organisation)
    person.activity_context = { 'skip_notifications' => false, 'bulk_run_id' => 'x' }

    expect(person.activity_context).to include('skip_notifications' => true, 'bulk_run_id' => 'x')
  end

  # Activity has no broadcast of its own any more (activity.rb); this pins that
  # a person write does not start one either (no Turbo broadcast job, no job at all).
  it 'enqueues no job, so no broadcast' do
    expect do
      person = create_person
      person.update!(phone: '1')
      person.destroy!
    end.not_to have_enqueued_job
  end
end
