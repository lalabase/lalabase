# frozen_string_literal: true

require 'rails_helper'

# The one format of a pick in the link dialog (S2b): written by the dialog,
# read by the controller and by the dialog that draws a refused pick again.
RSpec.describe Meetings::ParticipantLinkChoice do
  let(:id) { SecureRandom.uuid }

  it 'writes a row as person:<id> and a member as member:<id>, and reads both back' do
    person = instance_double(Person, id: id)
    user = instance_double(User, id: SecureRandom.uuid)

    contact_value = described_class.value_for(People::Directory::Entry.new(kind: :contact, person: person))
    member_value = described_class.value_for(People::Directory::Entry.new(kind: :member, user: user, person: person))

    expect(contact_value).to eq("person:#{id}")
    expect(member_value).to eq("member:#{user.id}")
    expect(described_class.parse(contact_value)).to have_attributes(kind: :person, id: id)
    expect(described_class.parse(member_value)).to have_attributes(kind: :member, id: user.id)
  end

  it 'reads the new person' do
    expect(described_class.parse(described_class::NEW_PERSON)).to have_attributes(kind: :new_person, id: nil)
  end

  [nil, '', 'person:', 'user:%<id>s', 'person:%<id>s ', ' person:%<id>s', 'person:%<id>s:x', 'person:not-a-uuid',
   ['person:%<id>s']].each do |value|
    it "reads nothing from #{value.inspect}" do
      value = format(value, id: id) if value.is_a?(String)

      expect(described_class.parse(value)).to be_nil
    end
  end
end
