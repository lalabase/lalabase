# frozen_string_literal: true

require 'rails_helper'

# The people directory is a right of its own (D7): account admins without a
# row, everyone else only with view_people / manage_people, and only while the
# membership is active.
RSpec.describe PersonPolicy, :ci_guard, type: :policy do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  def role_with(*actions, billable: true, title: nil)
    role = create(:role, organisation: organisation, billable: billable, **{ title: title }.compact)
    actions.each { |action| create(:permission, role: role, category: 'people', action: action, allowed: true) }
    role
  end

  def member_with(role, active: true)
    user = create(:user)
    create(:membership, user: user, organisation: organisation, role: role, active: active)
    User.find(user.id)
  end

  let(:admin) { member_with(role_with(title: Role::ACCOUNT_ADMIN_TITLE)) }
  let(:viewer) { member_with(role_with('view_people')) }
  let(:manager) { member_with(role_with('manage_people')) }
  let(:nobody) { member_with(role_with) }
  let(:guest_manager) { member_with(role_with('manage_people', billable: false)) }
  let(:person) { create(:person, organisation: organisation) }

  def allowed(user, record = person)
    policy = described_class.new(user, record)
    %i[index? show? create? update? destroy?].select { |predicate| policy.public_send(predicate) }
  end

  it 'lets an account admin do everything without a permission row' do
    expect(Permission.where(category: 'people').exists?).to be(false)
    expect(allowed(admin)).to eq(%i[index? show? create? update? destroy?])
  end

  it 'lets view_people read, not write' do
    expect(allowed(viewer)).to eq(%i[index? show?])
  end

  it 'lets manage_people read, write and delete' do
    expect(allowed(manager)).to eq(%i[index? show? create? update? destroy?])
  end

  it 'denies a member without the right' do
    expect(allowed(nobody)).to be_empty
  end

  it 'lets a guest role (billable: false) with manage_people write' do
    expect(allowed(guest_manager)).to eq(%i[index? show? create? update? destroy?])
  end

  it 'denies a deactivated member who still holds the right' do
    user = member_with(role_with('manage_people'), active: false)

    expect(allowed(user)).to be_empty
  end

  it 'denies a deactivated account admin' do
    user = member_with(role_with(title: Role::ACCOUNT_ADMIN_TITLE), active: false)

    expect(allowed(user)).to be_empty
  end

  it 'denies a record of another organisation' do
    theirs = ActsAsTenant.with_tenant(other_organisation) { create(:person, organisation: other_organisation) }

    expect(allowed(admin, theirs)).to eq(%i[index? create?])
  end

  describe 'Scope' do
    let(:visible_project) { create(:project, organisation: organisation) }
    let(:foreign_project) { create(:project, organisation: organisation) }
    let(:colleague) { member_with(role_with) }
    let(:stranger) { member_with(role_with) }

    before do
      create(:project_permission, user: viewer, project: visible_project, tickets_access: :read_only)
      create(:project_permission, user: colleague, project: visible_project, tickets_access: :read_only)
      create(:project_permission, user: stranger, project: foreign_project, tickets_access: :read_only)
    end

    def rows(user)
      described_class::Scope.new(User.find(user.id), Person).resolve
    end

    it 'hides a row linked to a member the viewer cannot see, and keeps the rest' do
      contact = create(:person, organisation: organisation)
      colleague_row = create(:person, organisation: organisation, user: colleague)
      stranger_row = create(:person, organisation: organisation, user: stranger)

      expect(rows(viewer)).to contain_exactly(contact, colleague_row)
      expect(rows(admin)).to contain_exactly(contact, colleague_row, stranger_row)
    end

    it 'denies show by id for a row linked to an invisible member' do
      stranger_row = create(:person, organisation: organisation, user: stranger)

      expect(described_class.new(User.find(viewer.id), stranger_row).show?).to be(false)
    end

    it 'denies update and destroy of a row linked to an invisible member, even with manage_people' do
      create(:project_permission, user: manager, project: visible_project, tickets_access: :read_only)
      stranger_row = create(:person, organisation: organisation, user: stranger)
      policy = described_class.new(User.find(manager.id), stranger_row)

      expect([policy.update?, policy.destroy?]).to eq([false, false])
    end

    it 'shows a row linked to a former member as a contact' do
      former_row = create(:person, organisation: organisation, user: stranger)
      Membership.find_by(user: stranger, organisation: organisation).update!(active: false)

      expect(rows(viewer)).to include(former_row)
    end

    it 'returns nothing without the right' do
      create(:person, organisation: organisation)

      expect(rows(nobody)).to be_empty
    end

    it 'never returns a row of another organisation' do
      ActsAsTenant.with_tenant(other_organisation) { create(:person, organisation: other_organisation) }

      expect(rows(admin)).to be_empty
    end
  end
end
