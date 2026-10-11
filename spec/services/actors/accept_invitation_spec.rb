# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Actors::AcceptInvitation, :ci_guard, type: :service do
  let(:organisation) { create(:organisation) }
  let(:inviter) { create(:user) }

  before do
    ActsAsTenant.current_tenant = organisation
    create(:membership, user: inviter, organisation: organisation)
  end

  describe '#call' do
    context 'happy path: existing user, signed in as that account, accepts valid invitation' do
      let(:existing_user) { create(:user) }
      let(:invitation) do
        create(:invitation,
               organisation: organisation,
               email: existing_user.email,
               inviter: inviter,
               sent_at: 1.hour.ago)
      end

      it 'accepts the invitation and creates a membership' do
        result = described_class.new(
          invitation: invitation,
          current_user: existing_user
        ).call

        expect(result).to be_success
        expect(invitation.reload.accepted_at).to be_present
        expect(Membership.exists?(user: existing_user, organisation: organisation)).to be true
      end

      it 'assigns the member role' do
        described_class.new(
          invitation: invitation,
          current_user: existing_user
        ).call

        membership = Membership.find_by(user: existing_user, organisation: organisation)
        expect(membership.role).to be_present
      end

      it 'does not create a new user' do
        existing_user # force creation before counting
        expect do
          described_class.new(
            invitation: invitation,
            current_user: existing_user
          ).call
        end.not_to change(User, :count)
      end
    end

    # Account takeover guard (26.09.2026): the actor itself refuses to attach an
    # existing account unless the caller is signed in as exactly that account,
    # whatever the controller in front of it does. A password is no substitute:
    # this door has neither Devise lockable nor the sign-in throttle.
    context 'security: existing account without a matching current_user' do
      let(:existing_user) { create(:user, email: 'victim@example.com') }
      let(:invitation) do
        create(:invitation,
               organisation: organisation,
               email: existing_user.email,
               inviter: inviter,
               sent_at: 1.hour.ago)
      end

      shared_examples 'refuses to attach the existing account' do
        it 'fails with invitation_requires_sign_in and changes nothing' do
          result = described_class.new(
            invitation: invitation,
            password: 'attackerPicked1!',
            password_confirmation: 'attackerPicked1!',
            current_user: signed_in_as
          ).call

          expect(result).not_to be_success
          expect(result.errors).to eq(['invitation_requires_sign_in'])
          expect(result.code).to eq(:invitation_requires_sign_in)
          expect(invitation.reload.accepted_at).to be_nil
          expect(Membership.exists?(user: existing_user, organisation: organisation)).to be(false)
        end
      end

      context 'when nobody is signed in' do
        let(:signed_in_as) { nil }

        it_behaves_like 'refuses to attach the existing account'
      end

      context 'when signed in as another account' do
        let(:signed_in_as) { create(:user) }

        it_behaves_like 'refuses to attach the existing account'
      end

      it 'finds the account whatever the case of the invitation address' do
        invitation.update_column(:email, 'Victim@Example.COM')

        result = described_class.new(invitation: invitation, current_user: nil).call

        expect(result.errors).to eq(['invitation_requires_sign_in'])
        expect(User.where('LOWER(email) = ?', 'victim@example.com').count).to eq(1)
      end

      # The owner's REAL password must not open this door either: a password
      # check here would have neither Devise lockable nor the sign-in throttle.
      it 'refuses even with the account owner\'s correct password' do
        existing_user.update!(password: 'victimsOwnPass1!', password_confirmation: 'victimsOwnPass1!')

        result = described_class.new(
          invitation: invitation,
          password: 'victimsOwnPass1!',
          password_confirmation: 'victimsOwnPass1!',
          current_user: nil
        ).call

        expect(result.errors).to eq(['invitation_requires_sign_in'])
        expect(Membership.exists?(user: existing_user, organisation: organisation)).to be(false)
      end

      it 'finds the account despite surrounding whitespace in the invitation address' do
        invitation.update_column(:email, "  #{existing_user.email}\t")

        result = described_class.new(invitation: invitation, current_user: nil).call

        expect(result.errors).to eq(['invitation_requires_sign_in'])
        expect(User.where('LOWER(email) = ?', 'victim@example.com').count).to eq(1)
      end

      it 'reports that it created no user when the account owner accepts' do
        actor = described_class.new(invitation: invitation, current_user: existing_user)

        expect(actor.call).to be_success
        expect(actor.created_user?).to be(false)
        expect(actor.created_user).to be_nil
      end
    end

    # current_user: has no default on purpose: a caller that forgets it must
    # fail loudly instead of silently running as "nobody signed in".
    it 'requires current_user: as a keyword' do
      invitation = create(:invitation, organisation: organisation, inviter: inviter, sent_at: 1.hour.ago)

      expect { described_class.new(invitation: invitation) }
        .to raise_error(ArgumentError, /current_user/)
    end

    context 'happy path: new user accepts valid invitation' do
      let(:new_email) { 'new_user@example.com' }
      let(:invitation) do
        create(:invitation,
               organisation: organisation,
               email: new_email,
               inviter: inviter,
               sent_at: 1.hour.ago)
      end

      it 'creates a new user and membership' do
        result = described_class.new(
          invitation: invitation,
          password: 'securePassword1!',
          password_confirmation: 'securePassword1!',
          current_user: nil
        ).call

        expect(result).to be_success
        new_user = User.find_by(email: new_email)
        expect(new_user).to be_present
        expect(Membership.exists?(user: new_user, organisation: organisation)).to be true
        expect(invitation.reload.accepted_at).to be_present
      end

      it 'reports the user it created, so only that one may be signed in' do
        actor = described_class.new(
          invitation: invitation,
          password: 'securePassword1!',
          password_confirmation: 'securePassword1!',
          current_user: nil
        )

        expect(actor.call).to be_success
        expect(actor.created_user?).to be(true)
        expect(actor.created_user).to eq(User.find_by(email: new_email))
      end

      it 'reports no created user when the creation fails' do
        actor = described_class.new(
          invitation: invitation,
          password: 'securePassword1!',
          password_confirmation: 'different456',
          current_user: nil
        )

        expect(actor.call).not_to be_success
        expect(actor.created_user?).to be(false)
      end

      it 'creates exactly one user and one membership' do
        expect do
          described_class.new(
            invitation: invitation,
            password: 'securePassword1!',
            password_confirmation: 'securePassword1!',
            current_user: nil
          ).call
        end.to change(User, :count).by(1)
                                   .and change(Membership, :count).by(1)
      end
    end

    context 'terms acceptance timestamp (GDPR proof)' do
      it 'stamps terms_accepted_at when creating a new invited user' do
        invitation = create(:invitation,
                            organisation: organisation,
                            email: 'fresh_invitee@example.com',
                            inviter: inviter,
                            sent_at: 1.hour.ago)

        described_class.new(
          invitation: invitation,
          password: 'securePassword1!',
          password_confirmation: 'securePassword1!',
          current_user: nil
        ).call

        expect(User.find_by(email: 'fresh_invitee@example.com').terms_accepted_at).to be_present
      end

      it 'preserves an existing acceptance timestamp for an already-registered user' do
        original_time = 3.days.ago
        existing_user = create(:user, terms_accepted_at: original_time)
        invitation = create(:invitation,
                            organisation: organisation,
                            email: existing_user.email,
                            inviter: inviter,
                            sent_at: 1.hour.ago)

        described_class.new(
          invitation: invitation,
          current_user: existing_user
        ).call

        expect(existing_user.reload.terms_accepted_at).to be_within(1.second).of(original_time)
      end

      it 'stamps terms_accepted_at for an existing user who never accepted before' do
        existing_user = create(:user, terms_accepted_at: nil)
        invitation = create(:invitation,
                            organisation: organisation,
                            email: existing_user.email,
                            inviter: inviter,
                            sent_at: 1.hour.ago)

        described_class.new(
          invitation: invitation,
          current_user: existing_user
        ).call

        expect(existing_user.reload.terms_accepted_at).to be_present
      end
    end

    context 'edge case: invitation already accepted' do
      let(:invitation) do
        create(:invitation,
               organisation: organisation,
               email: 'someone@example.com',
               inviter: inviter,
               sent_at: 1.hour.ago,
               accepted_at: 30.minutes.ago)
      end

      it 'returns failure with invitation_already_accepted error' do
        result = described_class.new(
          invitation: invitation,
          password: 'irrelevant',
          password_confirmation: 'irrelevant',
          current_user: nil
        ).call

        expect(result).not_to be_success
        expect(result.errors).to include('invitation_already_accepted')
      end

      it 'does not create a membership' do
        expect do
          described_class.new(
            invitation: invitation,
            password: 'irrelevant',
            password_confirmation: 'irrelevant',
            current_user: nil
          ).call
        end.not_to change(Membership, :count)
      end
    end

    context 'edge case: invitation expired (out_of_date)' do
      let(:invitation) do
        create(:invitation,
               organisation: organisation,
               email: 'someone@example.com',
               inviter: inviter,
               sent_at: 4.days.ago)
      end

      it 'returns failure with invitation_out_of_date error' do
        result = described_class.new(
          invitation: invitation,
          password: 'irrelevant',
          password_confirmation: 'irrelevant',
          current_user: nil
        ).call

        expect(result).not_to be_success
        expect(result.errors).to include('invitation_out_of_date')
      end

      it 'does not create a membership' do
        expect do
          described_class.new(
            invitation: invitation,
            password: 'irrelevant',
            password_confirmation: 'irrelevant',
            current_user: nil
          ).call
        end.not_to change(Membership, :count)
      end

      it 'does not modify the invitation' do
        described_class.new(
          invitation: invitation,
          password: 'irrelevant',
          password_confirmation: 'irrelevant',
          current_user: nil
        ).call

        expect(invitation.reload.accepted_at).to be_nil
      end
    end

    context 'edge case: new user with mismatched passwords' do
      let(:invitation) do
        create(:invitation,
               organisation: organisation,
               email: 'new_user@example.com',
               inviter: inviter,
               sent_at: 1.hour.ago)
      end

      it 'returns failure and does not create user or membership' do
        result = described_class.new(
          invitation: invitation,
          password: 'password123',
          password_confirmation: 'different456',
          current_user: nil
        ).call

        expect(result).not_to be_success
        expect(result.errors).to be_present
        expect(User.exists?(email: 'new_user@example.com')).to be false
        expect(invitation.reload.accepted_at).to be_nil
      end
    end

    context 'edge case: new user with blank password' do
      let(:invitation) do
        create(:invitation,
               organisation: organisation,
               email: 'new_user@example.com',
               inviter: inviter,
               sent_at: 1.hour.ago)
      end

      it 'returns failure' do
        result = described_class.new(
          invitation: invitation,
          password: '',
          password_confirmation: '',
          current_user: nil
        ).call

        expect(result).not_to be_success
        expect(User.exists?(email: 'new_user@example.com')).to be false
      end
    end

    context 'edge case: user already has membership in organisation' do
      let(:existing_user) { create(:user) }
      let(:invitation) do
        create(:invitation,
               organisation: organisation,
               email: existing_user.email,
               inviter: inviter,
               sent_at: 1.hour.ago)
      end

      before do
        create(:membership, user: existing_user, organisation: organisation)
      end

      it 'returns failure due to uniqueness constraint' do
        result = described_class.new(
          invitation: invitation,
          current_user: existing_user
        ).call

        expect(result).not_to be_success
        expect(result.errors).to be_present
      end

      it 'does not mark the invitation as accepted (transaction rollback)' do
        described_class.new(
          invitation: invitation,
          current_user: existing_user
        ).call

        expect(invitation.reload.accepted_at).to be_nil
      end
    end

    context 'edge case: transaction rollback on membership failure' do
      let(:invitation) do
        create(:invitation,
               organisation: organisation,
               email: 'new_user@example.com',
               inviter: inviter,
               sent_at: 1.hour.ago)
      end

      it 'rolls back user creation if membership creation fails' do
        # Simulate membership creation failure
        allow(Membership).to receive(:create!).and_raise(
          ActiveRecord::RecordInvalid.new(Membership.new)
        )

        result = described_class.new(
          invitation: invitation,
          password: 'securePassword1!',
          password_confirmation: 'securePassword1!',
          current_user: nil
        ).call

        expect(result).not_to be_success
        expect(User.exists?(email: 'new_user@example.com')).to be false
        expect(invitation.reload.accepted_at).to be_nil
      end
    end

    context 'edge case: invitation with sent_at nil' do
      let(:invitation) do
        inv = build(:invitation,
                    organisation: organisation,
                    email: 'someone@example.com',
                    inviter: inviter,
                    sent_at: nil)
        inv.save!(validate: false)
        inv
      end

      it 'fails cleanly as out of date (nil sent_at proves no freshness)' do
        # Behaviour change, on purpose (onboarding S1 hardening): the previous
        # characterization test pinned a CRASH here — Invitation#out_of_date?
        # had no nil-guard and NoMethodError'd. The guard now treats a
        # never-sent invitation as expired, so the actor returns the same
        # domain failure as any stale token instead of blowing up.
        result = described_class.new(
          invitation: invitation,
          password: 'irrelevant',
          password_confirmation: 'irrelevant',
          current_user: nil
        ).call

        expect(result.success?).to be(false)
        expect(result.errors).to include('invitation_out_of_date')
      end
    end

    context 'result object contract' do
      let(:existing_user) { create(:user) }
      let(:invitation) do
        create(:invitation,
               organisation: organisation,
               email: existing_user.email,
               inviter: inviter,
               sent_at: 1.hour.ago)
      end

      it 'returns the invitation as resource on success' do
        result = described_class.new(
          invitation: invitation,
          current_user: existing_user
        ).call

        expect(result.resource).to eq(invitation)
      end

      it 'returns empty errors on success' do
        result = described_class.new(
          invitation: invitation,
          current_user: existing_user
        ).call

        expect(result.errors).to be_empty
      end

      it 'returns the invitation as resource on failure' do
        invitation.update_column(:accepted_at, Time.current)

        result = described_class.new(
          invitation: invitation,
          current_user: existing_user
        ).call

        expect(result.resource).to eq(invitation)
      end
    end
  end
end
