# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Person, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def member_of(org, active: true)
    user = create(:user)
    create(:membership, user: user, organisation: org, active: active)
    user
  end

  it 'is bound to the tenant' do
    mine = create(:person, organisation: organisation)
    theirs = ActsAsTenant.with_tenant(other_organisation) { create(:person, organisation: other_organisation) }

    expect(described_class.all).to contain_exactly(mine)
    expect(described_class.unscoped.where(id: theirs.id)).to exist
  end

  it 'requires a name' do
    person = build(:person, organisation: organisation, name: '   ')

    expect(person).not_to be_valid
    expect(person.errors[:name]).to be_present
  end

  it 'squeezes the name and stores its normalized form' do
    person = create(:person, organisation: organisation, name: '  Jürgen   Müller ')

    expect(person.name).to eq('Jürgen Müller')
    expect(person.normalized_name).to eq('juergen mueller')
  end

  it 'refuses a malformed email and accepts none' do
    expect(build(:person, organisation: organisation, email: 'not an address')).not_to be_valid
    expect(build(:person, organisation: organisation, email: '')).to be_valid
  end

  describe 'the salutation' do
    it 'keeps free text as written, squeezed' do
      person = create(:person, organisation: organisation, salutation: '  Frau   Dr. ')

      expect(person.salutation).to eq('Frau Dr.')
    end

    it 'stores a blank salutation as none' do
      expect(create(:person, organisation: organisation, salutation: '   ').salutation).to be_nil
    end

    it 'refuses a salutation longer than a field' do
      person = build(:person, organisation: organisation, salutation: 'x' * (Person::MAX_FIELD_LENGTH + 1))

      expect(person).not_to be_valid
      expect(person.errors[:salutation]).to be_present
    end
  end

  describe 'the member link' do
    it 'accepts an active member of the same organisation' do
      expect(build(:person, organisation: organisation, user: member_of(organisation))).to be_valid
    end

    it 'refuses a member of another organisation' do
      person = build(:person, organisation: organisation, user: member_of(other_organisation))

      expect(person).not_to be_valid
      expect(person.errors.details[:user]).to include(error: :not_an_active_member)
    end

    it 'refuses a deactivated member' do
      person = build(:person, organisation: organisation, user: member_of(organisation, active: false))

      expect(person).not_to be_valid
    end

    it 'allows at most one row per member and organisation' do
      user = member_of(organisation)
      create(:person, organisation: organisation, user: user)

      expect(build(:person, organisation: organisation, user: user)).not_to be_valid
    end

    it 'keeps a stored link valid after the member was deactivated (only a NEW link is checked)' do
      user = member_of(organisation)
      person = create(:person, organisation: organisation, user: user)
      Membership.find_by(user: user, organisation: organisation).update!(active: false)

      expect(person.reload.update(phone: '+49 30 1234567')).to be(true)
    end
  end

  it 'raises on a stale save (both sides edit the same row)' do
    person = create(:person, organisation: organisation)
    first = described_class.find(person.id)
    second = described_class.find(person.id)
    first.update!(phone: '1')

    expect { second.update!(phone: '2') }.to raise_error(ActiveRecord::StaleObjectError)
  end
end
