# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::DestroyPerson do
  let(:organisation) { create(:organisation) }
  let(:writer) { create(:user, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  it 'deletes the row and leaves one anonymous deleted activity by the writer' do
    person = create(:person, organisation: organisation, name: 'Erika Geheim')

    result = described_class.call(person: person, current_user: writer)

    expect(result).to be_success
    expect(Person.exists?(person.id)).to be(false)
    activities = Activity.where(trackable_type: 'Person', trackable_id: person.id)
    expect(activities.map { |a| [a.action, a.actor] }).to eq([['deleted', writer]])
    expect(activities.first.parameters.to_json).not_to include('Erika')
  end
end
