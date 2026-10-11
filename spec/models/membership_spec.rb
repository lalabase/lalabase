# frozen_string_literal: true

# == Schema Information
#
# Table name: memberships
#
#  id              :uuid             not null, primary key
#  active          :boolean          default(TRUE), not null
#  role            :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  role_id         :uuid
#  user_id         :uuid             not null
#
# Indexes
#
#  index_memberships_on_organisation_id              (organisation_id)
#  index_memberships_on_role_id                      (role_id)
#  index_memberships_on_user_id                      (user_id)
#  index_memberships_on_user_id_and_organisation_id  (user_id,organisation_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (role_id => roles.id)
#
require 'rails_helper'

RSpec.describe Membership, type: :model do
  let(:organisation) { create(:organisation) }

  describe 'validations' do
    context 'uniqueness validation' do
      it 'validates uniqueness of user within organisation' do
        ActsAsTenant.with_tenant(organisation) do
          user = create(:user)
          create(:membership, user: user, organisation: organisation)

          duplicate_membership = build(:membership, user: user, organisation: organisation)
          expect(duplicate_membership).not_to be_valid
          expect(duplicate_membership.errors[:user_id]).to be_present
        end
      end
    end

    context 'active validation' do
      it 'validates that active is a boolean' do
        ActsAsTenant.with_tenant(organisation) do
          # Should accept true
          membership = build(:membership, active: true, organisation: organisation)
          expect(membership).to be_valid

          # Should accept false
          membership = build(:membership, active: false, organisation: organisation)
          expect(membership).to be_valid

          # Should not accept nil (converts to false in database, but validates before saving)
          membership = build(:membership, active: nil, organisation: organisation)
          expect(membership).not_to be_valid
          expect(membership.errors[:active]).to be_present
        end
      end
    end
  end

  describe 'associations' do
    it { should belong_to(:role).optional(true) }

    it 'creates membership with expected attributes' do
      ActsAsTenant.with_tenant(organisation) do
        membership = create(:membership, organisation: organisation, active: true)
        expect(membership.user).to be_present
        expect(membership.role).to be_present
        expect(membership.active).to be true
      end
    end
  end

  describe 'scopes' do
    let(:user) { create(:user) }

    before do
      ActsAsTenant.with_tenant(organisation) do
        create(:membership, user: user, organisation: organisation, active: true)
        create(:membership, organisation: organisation, active: false)
      end
    end

    it '.active returns only active memberships' do
      ActsAsTenant.with_tenant(organisation) do
        expect(Membership.active.count).to eq(1)
        expect(Membership.active.first.active).to be true
      end
    end

    it '.inactive returns only inactive memberships' do
      ActsAsTenant.with_tenant(organisation) do
        expect(Membership.inactive.count).to eq(1)
        expect(Membership.inactive.first.active).to be false
      end
    end
  end

  describe 'callbacks' do
    describe '#assign_default_role' do
      let(:user) { create(:user) }
      let(:default_role) do
        ActsAsTenant.with_tenant(organisation) do
          create(:role, organisation: organisation, is_default: true)
        end
      end

      context 'when role is not provided' do
        it 'assigns the default role after creation' do
          # Ensure default role exists
          default_role

          ActsAsTenant.with_tenant(organisation) do
            # Create membership without role
            membership = create(:membership, user: user, organisation: organisation, role: nil)

            # Expect default role to be assigned
            expect(membership.reload.role).to eq(default_role)
          end
        end

        it 'creates a default role if none exists' do
          ActsAsTenant.with_tenant(organisation) do
            expect do
              create(:membership, user: user, organisation: organisation, role: nil)
            end.to change(Role, :count).by(1)

            expect(organisation.roles.find_by(is_default: true)).to be_present
          end
        end
      end

      context 'when role is provided' do
        let(:custom_role) do
          ActsAsTenant.with_tenant(organisation) do
            create(:role, organisation: organisation)
          end
        end

        it 'keeps the provided role' do
          ActsAsTenant.with_tenant(organisation) do
            membership = create(:membership, user: user, organisation: organisation, role: custom_role)
            expect(membership.role).to eq(custom_role)
          end
        end
      end
    end
  end

  describe 'multi-tenant behavior' do
    let(:organisation1) { create(:organisation) }
    let(:organisation2) { create(:organisation) }
    let(:user) { create(:user) }

    it 'allows the same user to be a member of multiple organisations' do
      membership1 = nil
      membership2 = nil

      ActsAsTenant.with_tenant(organisation1) do
        membership1 = create(:membership, user: user, organisation: organisation1)
      end

      ActsAsTenant.with_tenant(organisation2) do
        membership2 = create(:membership, user: user, organisation: organisation2)
      end

      expect(membership1).to be_valid
      expect(membership2).to be_valid
      expect(user.memberships.count).to eq(2)
    end

    it 'enforces user uniqueness within the same organisation' do
      ActsAsTenant.with_tenant(organisation1) do
        create(:membership, user: user, organisation: organisation1)

        expect do
          create(:membership, user: user, organisation: organisation1)
        end.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe 'role management' do
    let(:user) { create(:user) }
    let(:admin_role) do
      ActsAsTenant.with_tenant(organisation) do
        create(:role, organisation: organisation, title: 'account_admin')
      end
    end

    it 'associates a user with a role in an organisation' do
      ActsAsTenant.with_tenant(organisation) do
        membership = create(:membership, user: user, organisation: organisation, role: admin_role)

        expect(membership.role).to eq(admin_role)
        expect(user.role_in_organisation(organisation)).to eq(admin_role)
      end
    end

    it 'allows changing a user\'s role' do
      ActsAsTenant.with_tenant(organisation) do
        membership = create(:membership, user: user, organisation: organisation)
        original_role = membership.role

        new_role = create(:role, organisation: organisation, title: 'project_manager')
        membership.update(role: new_role)

        expect(membership.reload.role).to eq(new_role)
        expect(membership.role).not_to eq(original_role)
      end
    end
  end
end
