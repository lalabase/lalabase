# frozen_string_literal: true

require 'rails_helper'

# Taking a contact over into another organisation: a copy of chosen fields,
# read in the source's tenant through People::Lookup, written in the target's
# tenant through Actors::SavePerson. Every refusal answers alike and writes
# nothing in either organisation.
RSpec.describe Actors::TakeOverPerson, :ci_guard, :people_takeover do
  let(:north) { create(:organisation, name: 'Nord GmbH') }
  let(:south) { create(:organisation, name: 'Süd GmbH') }
  let(:viewer) { create(:user, first_name: 'Vera', last_name: 'Viewer') }
  let(:details) do
    [
      { 'kind' => 'phone', 'label' => 'Mobil', 'value' => '+49 170 0000001' },
      { 'kind' => 'url', 'label' => '', 'value' => 'https://example.com/netz' },
      { 'kind' => 'text', 'label' => 'Kürzel', 'value' => 'HS' }
    ]
  end
  let!(:source) do
    takeover_person(north, name: 'Herr Schmidt', salutation: 'Herr', function: 'Technik', department: 'IT',
                           company: 'Netz AG', email: 'schmidt@example.com', phone: '+49 30 1111111',
                           notes: 'Nur vormittags erreichbar', additional_details: details)
  end

  before do
    takeover_join(viewer, north, 'view_people')
    takeover_join(viewer, south, 'manage_people')
  end

  after { ActsAsTenant.current_tenant = nil }

  def take_over(person_id: source.id, target: south.id, fields: described_class::DEFAULT_FIELDS,
                confirm_duplicate: false, user: viewer, from: north)
    described_class.call(source_organisation: from, person_id: person_id, target_organisation_id: target,
                         fields: fields, confirm_duplicate: confirm_duplicate, current_user: user)
  end

  def copy_of(result)
    ActsAsTenant.with_tenant(south) { Person.find(result.resource.id) }
  end

  describe 'the copy' do
    it 'carries exactly the ticked fields and leaves the others empty' do
      result = take_over(fields: %w[function email])

      expect(result).to be_success
      copy = copy_of(result)
      expect(copy.organisation_id).to eq(south.id)
      expect(copy.attributes.slice('name', 'function', 'email'))
        .to eq('name' => 'Herr Schmidt', 'function' => 'Technik', 'email' => 'schmidt@example.com')
      expect(copy.attributes.values_at('salutation', 'department', 'company', 'phone', 'notes')).to all(be_nil)
      expect(copy.additional_details).to eq([])
      expect(copy.user_id).to be_nil
      expect(copy.creator_id).to eq(viewer.id)
    end

    it 'copies the default list without the notes' do
      copy = copy_of(take_over)

      expect(copy.attributes.slice('salutation', 'function', 'department', 'company', 'email', 'phone'))
        .to eq('salutation' => 'Herr', 'function' => 'Technik', 'department' => 'IT', 'company' => 'Netz AG',
               'email' => 'schmidt@example.com', 'phone' => '+49 30 1111111')
      expect(copy.notes).to be_nil
    end

    it 'carries the notes only when they are ticked' do
      copy = copy_of(take_over(fields: described_class::DEFAULT_FIELDS + ['notes']))

      expect(copy.notes).to eq('Nur vormittags erreichbar')
    end

    it 'keeps the additional details in order, with kind and label' do
      copy = copy_of(take_over(fields: ['additional_details']))

      expect(copy.additional_details).to eq(details)
    end

    it 'takes only names of FIELDS from the list, never a column it does not name' do
      other = create(:user)
      copy = copy_of(take_over(fields: ['user_id', 'creator_id', 'organisation_id', 'notes ', 'NAME', { 'notes' => '1' }, other.id]))

      expect(copy.user_id).to be_nil
      expect(copy.creator_id).to eq(viewer.id)
      expect(copy.organisation_id).to eq(south.id)
      expect(copy.notes).to be_nil
      expect(copy.function).to be_nil
    end

    it 'reads a fields list that is no list as nothing ticked' do
      copy = copy_of(take_over(fields: { 'notes' => '1' }))

      expect(copy.name).to eq('Herr Schmidt')
      expect(copy.notes).to be_nil
      expect(copy.function).to be_nil
    end

    it 'leaves the source row as it was' do
      before = ActsAsTenant.with_tenant(north) { source.reload.attributes }

      take_over(fields: described_class::FIELDS)

      after = ActsAsTenant.with_tenant(north) { source.reload.attributes }
      expect(after).to eq(before)
      expect(after.values_at('updated_at', 'lock_version')).to eq(before.values_at('updated_at', 'lock_version'))
    end

    it 'records in the target only that a person was created, naming no source' do
      # Under the request's tenant, the source, as the controller calls it: the
      # commit must still write the history entry into the target.
      result = ActsAsTenant.with_tenant(north) { take_over(fields: described_class::FIELDS) }

      activities = ActsAsTenant.with_tenant(south) { Activity.where(trackable_type: 'Person', trackable_id: result.resource.id).to_a }
      expect(activities.map(&:action)).to eq(['created'])
      expect(activities.first.organisation_id).to eq(south.id)
      dump = activities.first.attributes.to_json
      expect(dump).not_to include(north.id, source.id, 'Nord', 'Nur vormittags')
      expect(ActsAsTenant.with_tenant(north) { Activity.where(trackable_id: result.resource.id).count }).to eq(0)
    end

    it 'leaves no tenant behind' do
      take_over

      expect(ActsAsTenant.current_tenant).to be_nil
    end
  end

  describe 'one refusal' do
    let(:refusal) { [false, :not_found, [I18n.t('controllers.people.not_found')]] }

    def expect_refused(result)
      expect([result.success?, result.code, result.errors]).to eq(refusal)
    end

    def counts
      [takeover_count(north), takeover_count(south)]
    end

    it 'takes over a readable contact into a valid target (the control of this group)' do
      expect { expect(take_over).to be_success }.to change { counts }.from([1, 0]).to([1, 1])
    end

    it 'answers an unknown source id' do
      expect { expect_refused(take_over(person_id: SecureRandom.uuid)) }.not_to(change { counts })
    end

    it 'answers a malformed source id' do
      expect { expect_refused(take_over(person_id: 'person:x')) }.not_to(change { counts })
    end

    it 'answers a source of another organisation' do
      foreign = takeover_person(south, name: 'Frau Fremd')

      expect { expect_refused(take_over(person_id: foreign.id)) }.not_to(change { counts })
    end

    it 'answers a source the viewer may not read' do
      reader = takeover_join(create(:user), north)
      takeover_join(reader, south, 'manage_people')

      expect { expect_refused(take_over(user: reader)) }.not_to(change { counts })
    end

    it 'answers a member' do
      member = takeover_join(create(:user), north)
      row = takeover_person(north, name: 'Mia Mitglied', user: member)

      expect { expect_refused(take_over(person_id: row.id)) }.not_to(change { counts })
    end

    it 'answers the row of a deactivated member' do
      member = takeover_join(create(:user), north)
      row = takeover_person(north, name: 'Dora Deaktiviert', user: member)
      ActsAsTenant.with_tenant(north) { Membership.find_by!(user: member, organisation: north).update!(active: false) }

      expect { expect_refused(take_over(person_id: row.id)) }.not_to(change { counts })
    end

    it 'answers a target the viewer is no member of' do
      foreign = create(:organisation)

      expect { expect_refused(take_over(target: foreign.id)) }.not_to(change { counts })
    end

    it 'answers a target with a deactivated membership' do
      east = create(:organisation)
      takeover_join(viewer, east, 'manage_people', active: false)

      expect { expect_refused(take_over(target: east.id)) }.not_to(change { counts })
    end

    it 'answers a target without the right to create people' do
      west = create(:organisation)
      takeover_join(viewer, west, 'view_people')

      expect { expect_refused(take_over(target: west.id)) }.not_to(change { counts })
    end

    it 'answers the source organisation as its own target' do
      both = takeover_join(create(:user), north, 'manage_people')
      takeover_join(both, south, 'manage_people')
      expect(take_over(user: both)).to be_success

      expect { expect_refused(take_over(user: both, target: north.id)) }.not_to(change { counts })
    end

    { 'a malformed' => 'x', 'an empty' => '', 'a missing' => nil, 'a list as' => :list, 'a hash as' => :hash }.each do |label, value|
      it "answers #{label} target id" do
        target = { list: [south.id], hash: { 'id' => south.id } }.fetch(value, value)

        expect { expect_refused(take_over(target: target)) }.not_to(change { counts })
      end
    end

    it 'answers a source deleted after the dialog opened' do
      id = source.id
      ActsAsTenant.with_tenant(north) { source.destroy! }

      expect { expect_refused(take_over(person_id: id)) }.not_to(change { counts })
    end
  end

  describe 'a same-named entry in the target' do
    let!(:existing) { takeover_person(south, name: 'herr  schmidt', email: 'other@example.com') }

    it 'asks first, names only entries of the target and writes nothing' do
      takeover_person(north, name: 'HERR SCHMIDT')

      result = nil
      expect { result = take_over }.not_to(change { takeover_count(south) })

      expect([result.success?, result.code]).to eq([false, :duplicate])
      expect(result.errors.join).to include('herr  schmidt'.squish, 'Süd GmbH')
      expect(result.errors.join).not_to include('HERR SCHMIDT', 'Nord GmbH')
    end

    it 'creates the copy when the viewer confirmed' do
      result = nil
      expect { result = take_over(confirm_duplicate: true) }.to change { takeover_count(south) }.by(1)

      expect(result).to be_success
    end

    it 'asks again on a submit that is not confirmed' do
      take_over(confirm_duplicate: true)

      expect(take_over.code).to eq(:duplicate)
    end

    it 'counts a member of the target with the same name' do
      ActsAsTenant.with_tenant(south) { existing.destroy! }
      admin = takeover_join(create(:user), north, 'view_people')
      takeover_join(admin, south, title: Role::ACCOUNT_ADMIN_TITLE)
      takeover_join(create(:user, first_name: 'Herr', last_name: 'Schmidt'), south)

      result = take_over(user: admin)

      expect([result.code, result.errors.join]).to match([:duplicate, include('Herr Schmidt')])
    end
  end

  describe 'the dialog targets' do
    it 'lists the organisations where the viewer may create people, never the source' do
      user = takeover_join(create(:user), north, 'manage_people')
      takeover_join(user, south, 'manage_people')
      takeover_join(user, create(:organisation, name: 'West AG'), 'view_people')
      takeover_join(user, create(:organisation, name: 'Ost AG'), 'manage_people', active: false)
      admin_org = create(:organisation, name: 'Admin AG')
      takeover_join(user, admin_org, title: Role::ACCOUNT_ADMIN_TITLE)

      targets = described_class.targets_for(viewer: user, source: north)

      expect(targets.map(&:id)).to eq([admin_org.id, south.id])
      expect(ActsAsTenant.current_tenant).to be_nil
    end
  end
end
