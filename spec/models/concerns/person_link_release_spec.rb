# frozen_string_literal: true

require 'rails_helper'

# Leaving an organisation keeps the person row and drops only its link, on
# every path that removes a membership (members page and the operator's admin
# backend write the same table through two classes).
RSpec.describe PersonLinkRelease, type: :model do
  let(:organisation) { create(:organisation) }
  let(:other_organisation) { create(:organisation) }
  let(:admin_role) { create(:role, organisation: organisation, title: Role::ACCOUNT_ADMIN_TITLE) }
  let(:admin) { create(:user) }
  let(:user) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: admin, organisation: organisation, role: admin_role)
    create(:membership, user: user, organisation: organisation)
    create(:membership, user: user, organisation: other_organisation)
  end

  after { ActsAsTenant.current_tenant = nil }

  let!(:row) { create(:person, organisation: organisation, user: user, name: 'Mia Mitglied', phone: '1') }
  let!(:other_row) do
    ActsAsTenant.with_tenant(other_organisation) { create(:person, organisation: other_organisation, user: user) }
  end

  it 'keeps the row and drops the link when a member is removed on the members page' do
    membership = Membership.find_by(user: user, organisation: organisation)

    expect(RemoveMembershipService.new(membership: membership, admin: User.find(admin.id)).call).to be(true)

    expect(row.reload.user_id).to be_nil
    expect([row.name, row.phone]).to eq(['Mia Mitglied', '1'])
    expect(Person.unscoped.find(other_row.id).user_id).to eq(user.id)
  end

  it 'does the same when the operator removes the membership in the admin backend' do
    ActsAsTenant.current_tenant = nil
    Admin::Membership.find_by(user_id: user.id, organisation_id: organisation.id).destroy!

    expect(Person.unscoped.find(row.id).user_id).to be_nil
    expect(Person.unscoped.find(other_row.id).user_id).to eq(user.id)
  end

  it 'keeps the link when the membership is only deactivated' do
    Membership.find_by(user: user, organisation: organisation).update!(active: false)

    expect(row.reload.user_id).to eq(user.id)
  end
end
