# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::SavePerson do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE) }
  let(:writer) { member(role: admin_role) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def member(role: create(:role, organisation: organisation), active: true, org: organisation)
    user = create(:user, first_name: 'Mia', last_name: "Mitglied#{SecureRandom.hex(2)}")
    create(:membership, user: user, organisation: org, role: role, active: active)
    user
  end

  def save(id: nil, **params)
    described_class.call(organisation: organisation, params: params, current_user: writer, id: id)
  end

  it 'creates a contact with creator and updater' do
    result = save(name: 'Erika Beispiel', function: 'IT')

    expect(result).to be_success
    person = result.resource
    expect(person).to be_persisted
    expect([person.creator_id, person.updater_id]).to eq([writer.id, writer.id])
  end

  it 'saves and clears the salutation' do
    person = save(name: 'Müller', salutation: 'Frau Dr.').resource
    expect(person.salutation).to eq('Frau Dr.')

    save(salutation: '', lock_version: person.lock_version, id: person.id)

    expect(person.reload.salutation).to be_nil
  end

  it 'records the actor of the activity (Current.user from the actor)' do
    result = save(name: 'Erika Beispiel')

    expect(Activity.find_by!(trackable: result.resource, action: 'created').actor).to eq(writer)
  end

  it 'updates and moves the updater, keeping the creator' do
    person = save(name: 'Erika Beispiel').resource
    editor = member(role: admin_role)

    result = described_class.call(organisation: organisation, params: { phone: '1', lock_version: person.lock_version },
                                  current_user: editor, id: person.id)

    expect(result).to be_success
    expect(person.reload.phone).to eq('1')
    expect([person.creator_id, person.updater_id]).to eq([writer.id, editor.id])
  end

  it 'copies the member name when a link is set' do
    user = member
    result = save(name: 'egal', user_id: user.id)

    expect(result.resource.user).to eq(user)
    expect(result.resource.name).to eq(user.display_name)
  end

  # Only a link without any membership behind it can be dropped. Removing a
  # member releases the link by itself (PersonLinkRelease); delete_all skips
  # that callback and leaves such a link behind.
  it 'drops a link without a membership behind it when user_id is blank' do
    user = member
    person = save(name: 'x', user_id: user.id).resource
    Membership.where(user: user, organisation: organisation).delete_all

    save(user_id: '', lock_version: person.lock_version, id: person.id)

    expect(person.reload.user_id).to be_nil
    expect(person.name).to eq(user.display_name)
  end

  # Review of PR #64: deactivating can be undone, so the row is still that
  # member's. A new link would carry their phone and notes over to another
  # member, and an empty one would make the row a contact for every reader.
  # The name and email stay the row's own (round 3: the row's name is the one
  # shown).
  describe 'the row of a deactivated member' do
    let(:first_member) { member }
    let!(:row) { save(name: 'egal', user_id: first_member.id, phone: '1', notes: 'n').resource }

    before { Membership.where(user: first_member, organisation: organisation).update_all(active: false) }

    it 'keeps the link against another member' do
      result = save(user_id: member.id, lock_version: row.lock_version, id: row.id)

      expect(result).to be_success
      expect(row.reload.user_id).to eq(first_member.id)
    end

    it 'keeps the link against a blank user_id' do
      save(user_id: '', lock_version: row.lock_version, id: row.id)

      expect(row.reload.user_id).to eq(first_member.id)
    end

    it 'takes name and email from the request' do
      save(name: 'Eigener Name', email: 'e@example.com', lock_version: row.lock_version, id: row.id)

      expect([row.reload.name, row.email]).to eq(['Eigener Name', 'e@example.com'])
    end
  end

  # Review of S1 (28.10.2026): the form locks name, email and the link of an
  # active member's row and does not send them. A hand-made request must not
  # write them either: the name would surface once the member leaves, and a new
  # user_id would carry the first member's phone and notes over to another.
  describe 'the row of an active member' do
    let(:first_member) { member }
    let(:second_member) { member }
    let!(:row) { save(name: 'egal', user_id: first_member.id, phone: '1').resource }

    it 'keeps name, email and link against a hand-made request' do
      result = save(name: 'Gefaelscht', email: 'x@example.com', user_id: second_member.id, phone: '2',
                    lock_version: row.lock_version, id: row.id)

      expect(result).to be_success
      row.reload
      expect([row.name, row.email, row.user_id, row.phone]).to eq([first_member.display_name, nil, first_member.id, '2'])
    end

    it 'keeps the link against a blank user_id' do
      save(user_id: '', lock_version: row.lock_version, id: row.id)

      expect(row.reload.user_id).to eq(first_member.id)
    end

    it 'takes no email when the row is created for the member' do
      other = member
      created = save(name: 'egal', email: 'y@example.com', user_id: other.id).resource

      expect(created.email).to be_nil
    end
  end

  it 'refuses a raw user_id the writer may not link (another organisation)' do
    foreign = member(org: other_organisation)

    result = save(name: 'x', user_id: foreign.id)

    expect(result).not_to be_success
    expect(Person.count).to eq(0)
  end

  it 'refuses a member the writer cannot see' do
    viewer_role = create(:role, organisation: organisation)
    limited_writer = member(role: viewer_role)
    stranger = member
    project = create(:project, organisation: organisation)
    create(:project_permission, user: limited_writer, project: project, tickets_access: :read_only)

    result = described_class.call(organisation: organisation, params: { name: 'x', user_id: stranger.id },
                                  current_user: limited_writer)

    expect(result).not_to be_success
  end

  it 'maps a stale save to code :stale_object and keeps the newer value' do
    person = save(name: 'Erika Beispiel').resource
    stale_version = person.lock_version
    save(phone: 'first', lock_version: stale_version, id: person.id)

    result = save(phone: 'second', lock_version: stale_version, id: person.id)

    expect(result).not_to be_success
    expect(result.code).to eq(:stale_object)
    expect(person.reload.phone).to eq('first')
  end

  it 'answers not found for an id of another organisation' do
    theirs = ActsAsTenant.with_tenant(other_organisation) { create(:person, organisation: other_organisation) }

    result = save(phone: '1', id: theirs.id)

    expect(result).not_to be_success
    expect(result.code).to eq(:not_found)
    expect(Person.unscoped.find(theirs.id).phone).to be_nil
  end

  # Review round 1: two saves linking the same member at once. The unique index
  # answers the second; it must be a failure, not an unexpected error.
  it 'turns a lost race on the member link into a failure' do
    user = member
    allow_any_instance_of(Person).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)

    result = save(name: 'x', user_id: user.id)

    expect(result).not_to be_success
    expect(result.code).to eq(:validation_failed)
  end

  it 'maps a validation error to a failure' do
    result = save(name: '')

    expect(result).not_to be_success
    expect(result.code).to eq(:validation_failed)
  end
end
