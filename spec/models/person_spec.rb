# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Person, :ci_guard, type: :model do
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

  # Sharpened 28.10.2026 (tests-schaerfen): each rule below is held by one
  # example that breaks when the rule goes, in the model AND in the database.
  describe 'the fields' do
    # Every text column of the table, read from the database, not from TEXT_FIELDS:
    # a field dropped from the constant would take its own example with it. The
    # normalized name is derived from the name and checked through it.
    text_columns = described_class.columns.select { |column| column.type == :string }.map(&:name) - %w[normalized_name]

    it 'knows the text columns it limits' do
      expect(text_columns).to contain_exactly(*described_class::TEXT_FIELDS.map(&:to_s))
    end

    text_columns.map(&:to_sym).each do |field|
      it "accepts #{field} at #{Person::MAX_FIELD_LENGTH} characters and refuses one more" do
        value = field == :email ? "#{'a' * (Person::MAX_FIELD_LENGTH - 12)}@example.com" : 'x' * Person::MAX_FIELD_LENGTH
        longer = field == :email ? "a#{value}" : "#{value}x"

        expect(build(:person, organisation: organisation, field => value)).to be_valid
        too_long = build(:person, organisation: organisation, field => longer)
        expect(too_long).not_to be_valid
        expect(too_long.errors.details[field]).to include(a_hash_including(error: :too_long))
      end
    end

    it "accepts notes at #{Person::MAX_NOTES_LENGTH} characters and refuses one more" do
      expect(build(:person, organisation: organisation, notes: 'n' * Person::MAX_NOTES_LENGTH)).to be_valid
      too_long = build(:person, organisation: organisation, notes: 'n' * (Person::MAX_NOTES_LENGTH + 1))
      expect(too_long).not_to be_valid
      expect(too_long.errors.details[:notes]).to include(a_hash_including(error: :too_long))
    end

    ['erika@example.com', 'e.beispiel+team@sub.example.com'].each do |email|
      it "accepts the email #{email}" do
        expect(build(:person, organisation: organisation, email: email)).to be_valid
      end
    end

    ['erika@', '@example.com', 'erika example.com'].each do |email|
      it "refuses the email #{email.inspect}" do
        person = build(:person, organisation: organisation, email: email)

        expect(person).not_to be_valid
        expect(person.errors.details[:email]).to include(a_hash_including(error: :invalid))
      end
    end

    it 'accepts no email at all' do
      expect(build(:person, organisation: organisation, email: nil)).to be_valid
    end

    it 'starts at lock_version 0 without creator or updater (database defaults)' do
      person = described_class.create!(organisation: organisation, name: 'Erika Beispiel')

      expect(person.reload).to have_attributes(lock_version: 0, creator_id: nil, updater_id: nil, user_id: nil)
    end
  end

  describe 'the database behind the model' do
    it 'refuses a second row for the same member even past the validation' do
      user = member_of(organisation)
      create(:person, organisation: organisation, user: user)
      # validate: false skips before_validation too, so the normalized name is set by hand:
      # otherwise the NOT NULL constraint answers first and hides the index.
      racer = build(:person, organisation: organisation, user: user, normalized_name: 'racer')

      expect { racer.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # The member index must not reach contacts: a unique index on the organisation
    # alone, or one with NULLS NOT DISTINCT, would allow one contact per organisation.
    it 'keeps any number of contacts without a member in one organisation' do
      2.times { build(:person, organisation: organisation, user: nil, normalized_name: 'kontakt').save!(validate: false) }

      expect(described_class.unlinked.count).to eq(2)
    end

    it 'refuses a row without a name even past the validation' do
      person = described_class.new(organisation: organisation, name: nil, normalized_name: nil)

      expect { person.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it 'empties the member link when the user is deleted (on_delete: nullify)' do
      user = member_of(organisation)
      person = create(:person, organisation: organisation, user: user)
      Membership.where(user_id: user.id).delete_all
      User.where(id: user.id).delete_all

      expect(person.reload.user_id).to be_nil
      expect(person.name).to be_present
    end

    it 'empties creator and updater when their user is deleted, and keeps the row' do
      writer = create(:user)
      person = create(:person, organisation: organisation, creator: writer, updater: writer)
      User.where(id: writer.id).delete_all

      expect(person.reload).to have_attributes(creator_id: nil, updater_id: nil)
    end

    it 'leaves a meeting participant with its name when the person is deleted' do
      person = create(:person, organisation: organisation)
      meeting = create(:meeting, organisation: organisation, project: create(:project, organisation: organisation))
      participant = create(:meeting_participant, meeting: meeting, display_name: 'Erika Beispiel', person: person)

      described_class.where(id: person.id).delete_all

      expect(participant.reload).to have_attributes(person_id: nil, display_name: 'Erika Beispiel')
    end

    it 'goes with its organisation (dependent: :destroy)' do
      expect(Organisation.reflect_on_association(:people).options[:dependent]).to eq(:destroy)
    end
  end

  describe 'across scopes' do
    it 'lets the same member have a row in each organisation' do
      user = member_of(organisation)
      create(:membership, user: user, organisation: other_organisation, active: true)
      create(:person, organisation: organisation, user: user)

      ActsAsTenant.with_tenant(other_organisation) do
        expect(build(:person, organisation: other_organisation, user: user)).to be_valid
      end
    end

    # D3: the directory shows duplicates as a hint, it does not refuse them.
    it 'allows two rows with the same name in one organisation' do
      create(:person, organisation: organisation, name: 'Erika Beispiel')

      expect(build(:person, organisation: organisation, name: 'erika  BEISPIEL')).to be_valid
    end
  end

  describe 'linked rows' do
    it 'tells a linked row from a contact, also in the scopes' do
      linked = create(:person, organisation: organisation, user: member_of(organisation))
      contact = create(:person, organisation: organisation)

      expect([linked.linked?, contact.linked?]).to eq([true, false])
      expect(described_class.linked).to contain_exactly(linked)
      expect(described_class.unlinked).to contain_exactly(contact)
    end

    it 'orders by the normalized name' do
      zora = create(:person, organisation: organisation, name: 'Zora Zeta')
      anna = create(:person, organisation: organisation, name: 'anna Alpha')
      umlaut = create(:person, organisation: organisation, name: 'Änne Beta')

      expect(described_class.ordered.to_a).to eq([umlaut, anna, zora])
    end
  end

  describe '#stored_membership' do
    it 'is the membership behind the stored link, active or deactivated' do
      user = member_of(organisation)
      person = create(:person, organisation: organisation, user: user)
      membership = Membership.find_by(user: user, organisation: organisation)

      expect(person.stored_membership).to eq(membership)
      membership.update!(active: false)
      expect(person.reload.stored_membership).to eq(membership)
    end

    it 'reads the stored link, not an unsaved change' do
      first = member_of(organisation)
      person = create(:person, organisation: organisation, user: first)
      person.user = member_of(organisation)

      expect(person.stored_membership.user_id).to eq(first.id)
    end

    it 'is nil for a contact, a new row and a removed member' do
      user = member_of(organisation)
      linked = create(:person, organisation: organisation, user: user)

      expect(create(:person, organisation: organisation).stored_membership).to be_nil
      expect(build(:person, organisation: organisation, user: user).stored_membership).to be_nil
      Membership.find_by(user: user, organisation: organisation).destroy!
      expect(linked.reload.stored_membership).to be_nil
    end

    it 'does not take a membership of another organisation' do
      user = member_of(organisation)
      create(:membership, user: user, organisation: other_organisation, active: true)
      person = create(:person, organisation: organisation, user: user)
      Membership.where(user: user, organisation: organisation).delete_all

      expect(person.reload.stored_membership).to be_nil
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
