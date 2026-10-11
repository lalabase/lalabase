# frozen_string_literal: true

require 'rails_helper'

# S1 (assistant plan §5.3): once a thread belongs to a person, it is their private
# content, and the account erasure path has to take it with them.
#
# The FK never does that for us. `soft_delete_and_anonymize!` is a SOFT delete — no
# row is ever DELETEd — so `on_delete` never fires, and a `dependent: :destroy` on
# the association would be a dead promise that reads like a live one. The step
# lives in PersonalDataErasure (reached from soft_delete_and_anonymize! on both
# paths), next to the private meeting analyses, with an ActsAsTenant escape
# because a person spans organisations. This file guards the chat side in depth;
# the cross-path guard is spec/models/user_erasure_path_parity_spec.rb.
RSpec.describe User::DeletionLifecycle, type: :model do
  describe '#soft_delete_and_anonymize! and personal chats' do
    let(:organisation) { create(:organisation) }
    let(:other_organisation) { create(:organisation) }
    let(:project) { create(:project, organisation: organisation) }
    let(:user) { create(:user) }
    let(:colleague) { create(:user) }

    before do
      ActsAsTenant.current_tenant = organisation
      create(:membership, user: user, organisation: organisation,
                          role: create(:role, organisation: organisation), active: true)
    end

    after { ActsAsTenant.current_tenant = nil }

    it 'destroys the threads the erased account owned' do
      own = create(:chat, organisation: organisation, user: user)

      expect { user.soft_delete_and_anonymize! }
        .to change { ActsAsTenant.without_tenant { Chat.where(id: own.id).count } }.from(1).to(0)
    end

    it 'takes the posts of those threads with them' do
      own = create(:chat, organisation: organisation, user: user)
      post_ids = own.chatposts.pluck(:id)
      expect(post_ids).not_to be_empty

      user.soft_delete_and_anonymize!

      expect(ActsAsTenant.without_tenant { Chatpost.where(id: post_ids).count }).to eq(0)
    end

    # A person spans organisations, and the erasure is not tenant-scoped. Without the
    # ActsAsTenant escape this would finish "successfully" having cleaned exactly the
    # organisation that happened to be the current tenant.
    it 'reaches the threads in an organisation that is not the current tenant' do
      elsewhere = ActsAsTenant.with_tenant(other_organisation) do
        create(:project, organisation: other_organisation)
        create(:chat, organisation: other_organisation, user: user)
      end

      user.soft_delete_and_anonymize!

      expect(ActsAsTenant.without_tenant { Chat.where(id: elsewhere.id).count }).to eq(0)
    end

    it 'leaves a colleagues thread alone' do
      theirs = create(:chat, organisation: organisation, user: colleague)

      user.soft_delete_and_anonymize!

      expect(ActsAsTenant.without_tenant { Chat.where(id: theirs.id).count }).to eq(1)
    end

    # Was: "leaves an ownerless thread standing". projekt_chat_abbau made that shape
    # unreachable -- org_thread_has_owner and the DB check constraint
    # chats_org_thread_requires_user now bind every row, where they used to bind
    # project-less ones only. Rows written before the cut can still exist, and the
    # erasure walks `chats` by user_id, so a NULL owner is simply never matched. The
    # assertion that carries the same weight is the colleague's thread above.

    # The whole method runs in one transaction. If the erasure of the threads is
    # moved outside it, this example leaves a deleted thread behind a user that was
    # never erased.
    it 'is rolled back with the rest when a later step raises' do
      own = create(:chat, organisation: organisation, user: user)
      allow(user).to receive(:soft_delete!).and_raise(StandardError, 'boom')

      expect { user.soft_delete_and_anonymize! }.to raise_error(StandardError, 'boom')

      expect(ActsAsTenant.without_tenant { Chat.where(id: own.id).count }).to eq(1)
    end
    # Admin twin (CLAUDE.md, memory "Admin-Zwilling braucht dasselbe Concern"):
    # Admin::UsersController#destroy goes through DeleteAccountService to an
    # Admin::User, not to User. Its soft_delete_and_anonymize! is a SEPARATE
    # implementation. Without this case, personal threads stay behind when an
    # administrator deletes the account instead of the person themselves.
    it 'erases them on the admin deletion path too' do
      own = create(:chat, organisation: organisation, user: user)
      admin_twin = ActsAsTenant.without_tenant { Admin::User.find(user.id) }

      admin_twin.soft_delete_and_anonymize!

      expect(ActsAsTenant.without_tenant { Chat.where(id: own.id).count }).to eq(0)
    end

    it 'leaves a colleagues thread alone on the admin path as well' do
      theirs = create(:chat, organisation: organisation, user: colleague)
      admin_twin = ActsAsTenant.without_tenant { Admin::User.find(user.id) }

      admin_twin.soft_delete_and_anonymize!

      expect(ActsAsTenant.without_tenant { Chat.where(id: theirs.id).count }).to eq(1)
    end
  end
end
