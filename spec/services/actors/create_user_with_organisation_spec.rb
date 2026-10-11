# frozen_string_literal: true

require 'rails_helper'

# Actors::CreateUserWithOrganisation is the admin-backend counterpart of
# Actors::CreateOrganisation: it creates a new user AND bootstraps a fresh organisation
# (account_admin role + membership) in a single transaction, reusing OrganisationBootstrap.
#
# Key difference (decision D-D): in the admin backend the audit actor is a Beuser, never a
# User. Activity#actor is a `belongs_to ... class_name: 'User'`, so a Beuser there would be
# invalid. The bootstrapped models (Organisation/Role/Membership) are not Trackable, so no
# activity is created either way — the actor is therefore called with current_user: nil and
# must NOT set Current.user. The admin path operates on Admin:: models (tenant-bypassing).
RSpec.describe Actors::CreateUserWithOrganisation, type: :service do
  # Admin models bypass acts_as_tenant; mirror the admin backend, which runs without a tenant.
  before { ActsAsTenant.current_tenant = nil }

  let(:user) do
    Admin::User.new(first_name: 'Max', last_name: 'Mustermann', email: 'max@example.com',
                    active: true, password: 'secret123', password_confirmation: 'secret123')
  end
  let(:organisation) { Admin::Organisation.new(name: 'Admin-created Org') }

  subject(:actor) { described_class.new(user: user, organisation: organisation, current_user: nil) }

  describe '#call' do
    context 'with valid user and organisation' do
      it 'returns a successful Result' do
        expect(actor.call).to be_success
      end

      it 'creates the user, the organisation and the membership' do
        expect { actor.call }
          .to change(User, :count).by(1)
          .and change(Organisation, :count).by(1)
          .and change(Membership, :count).by(1)
      end

      it 'makes the new user an active account_admin member' do
        actor.call

        ActsAsTenant.without_tenant do
          membership = User.find(user.id).memberships.first
          expect(membership.active).to be true
          expect(membership.role.title).to eq(Role::ACCOUNT_ADMIN_TITLE)
        end
      end

      it 'does not set Current.user (the admin actor is a Beuser, passed as nil)' do
        Current.user = nil
        actor.call

        expect(Current.user).to be_nil
      end

      it 'returns the created user as the Result resource (record contract)' do
        result = actor.call

        expect(result.resource).to eq(user)
        expect(result.resource).to be_persisted
      end

      # D11: the admin-create path must NOT leave an orphan Account. ensure_account
      # builds it owner-less here (Current.user is nil, the actor is a Beuser), so
      # the actor sets the created account_admin as owner afterwards.
      it 'assigns the created user as the account owner (stops the orphan source)' do
        actor.call

        account = organisation.account
        expect(account.reload.owner_id).to eq(user.id)
        expect(account).not_to be_orphan
      end
    end

    # D9 guard: an inactive user must NOT be crowned owner (would create an
    # owner-who-cannot-sign-in on a badge-less, unmanageable Account). The
    # account stays a visible, claimable orphan instead.
    context 'when the created user is inactive (active: false)' do
      let(:user) do
        Admin::User.new(first_name: 'Ina', last_name: 'Ktiv', email: 'ina@example.com',
                        active: false, password: 'secret123', password_confirmation: 'secret123')
      end

      it 'succeeds but leaves the account owner-less (visible orphan, D9)' do
        expect(actor.call).to be_success

        account = organisation.account
        expect(account.reload.owner_id).to be_nil
        expect(account).to be_orphan
      end
    end

    context 'when the organisation is invalid (rollback)' do
      let(:organisation) { Admin::Organisation.new(name: '') }

      it 'rolls back the user creation (atomic)' do
        expect { actor.call }.not_to change(User, :count)
      end

      it 'returns a failure Result' do
        expect(actor.call).not_to be_success
      end
    end

    context 'when the user is invalid' do
      let(:user) { Admin::User.new(email: '', first_name: 'X', last_name: 'Y') }

      it 'creates no organisation' do
        expect { actor.call }.not_to change(Organisation, :count)
      end

      it 'returns a failure Result' do
        expect(actor.call).not_to be_success
      end
    end
  end
end
