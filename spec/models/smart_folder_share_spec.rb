# frozen_string_literal: true

# == Schema Information
#
# Table name: smart_folder_shares
#
#  id              :uuid             not null, primary key
#  can_edit        :boolean          default(FALSE)
#  can_share       :boolean          default(FALSE)
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  smart_folder_id :uuid             not null
#  user_id         :uuid             not null
#
# Indexes
#
#  index_smart_folder_shares_on_smart_folder_id              (smart_folder_id)
#  index_smart_folder_shares_on_smart_folder_id_and_user_id  (smart_folder_id,user_id) UNIQUE
#  index_smart_folder_shares_on_user_id                      (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (smart_folder_id => smart_folders.id)
#  fk_rails_...  (user_id => users.id)
#
require 'rails_helper'

RSpec.describe SmartFolderShare, type: :model do
  let(:organisation) { create(:organisation) }
  let(:owner) { create(:user, organisation: organisation) }
  let(:other_user) { create(:user, organisation: organisation) }
  let(:smart_folder) { create(:smart_folder, user: owner, organisation: organisation) }

  before { ActsAsTenant.current_tenant = organisation }
  after { ActsAsTenant.current_tenant = nil }

  describe 'associations' do
    it { is_expected.to belong_to(:smart_folder).inverse_of(:smart_folder_shares) }
    it { is_expected.to belong_to(:user) }
  end

  describe 'validations' do
    describe 'belongs_to presence (Rails 5+ default)' do
      it 'is invalid without a smart_folder' do
        share = described_class.new(user: other_user, smart_folder: nil)
        share.valid?
        expect(share.errors[:smart_folder]).to be_present
      end

      it 'is invalid without a user' do
        share = described_class.new(smart_folder: smart_folder, user: nil)
        share.valid?
        expect(share.errors[:user]).to be_present
      end
    end

    describe 'uniqueness of user_id scoped to smart_folder_id' do
      it 'prevents duplicate shares for same user and folder' do
        create(:smart_folder_share, smart_folder: smart_folder, user: other_user)
        duplicate = build(:smart_folder_share, smart_folder: smart_folder, user: other_user)

        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:user_id]).to be_present
      end

      it 'allows same user in different folders' do
        another_folder = create(:smart_folder, user: owner, organisation: organisation)
        create(:smart_folder_share, smart_folder: smart_folder, user: other_user)
        share_in_other = build(:smart_folder_share, smart_folder: another_folder, user: other_user)

        expect(share_in_other).to be_valid
      end

      it 'allows different users in same folder' do
        third_user = create(:user, organisation: organisation)
        create(:smart_folder_share, smart_folder: smart_folder, user: other_user)
        share_for_third = build(:smart_folder_share, smart_folder: smart_folder, user: third_user)

        expect(share_for_third).to be_valid
      end
    end

    describe '#not_sharing_with_owner' do
      it 'prevents sharing a folder with its owner' do
        share = build(:smart_folder_share, smart_folder: smart_folder, user: owner)

        expect(share).not_to be_valid
        expect(share.errors[:user_id]).to include(
          I18n.t('activerecord.errors.models.smart_folder_share.attributes.user_id.cannot_share_with_owner',
                 default: 'cannot_share_with_owner')
        )
      end

      it 'allows sharing with a non-owner user' do
        share = build(:smart_folder_share, smart_folder: smart_folder, user: other_user)

        expect(share).to be_valid
      end

      it 'does not raise when user is nil' do
        share = described_class.new(smart_folder: smart_folder, user: nil)

        expect { share.valid? }.not_to raise_error
      end

      it 'does not raise when smart_folder is nil' do
        share = described_class.new(smart_folder: nil, user: other_user)

        expect { share.valid? }.not_to raise_error
      end

      it 'does not raise when both are nil' do
        share = described_class.new(smart_folder: nil, user: nil)

        expect { share.valid? }.not_to raise_error
      end
    end
  end

  describe 'defaults' do
    it 'defaults can_edit to false' do
      share = described_class.new
      expect(share.can_edit).to be false
    end

    it 'defaults can_share to false' do
      share = described_class.new
      expect(share.can_share).to be false
    end
  end

  describe 'persistence' do
    it 'creates a valid share' do
      share = build(:smart_folder_share, smart_folder: smart_folder, user: other_user)

      expect { share.save! }.to change(described_class, :count).by(1)
    end

    it 'persists can_edit and can_share flags' do
      share = create(:smart_folder_share, smart_folder: smart_folder, user: other_user,
                                          can_edit: true, can_share: true)
      share.reload

      expect(share.can_edit).to be true
      expect(share.can_share).to be true
    end

    it 'is destroyed when smart_folder is destroyed' do
      create(:smart_folder_share, smart_folder: smart_folder, user: other_user)

      expect { smart_folder.destroy }.to change(described_class, :count).by(-1)
    end
  end

  describe 'database constraints' do
    it 'enforces uniqueness at database level' do
      create(:smart_folder_share, smart_folder: smart_folder, user: other_user)

      duplicate = build(:smart_folder_share, smart_folder: smart_folder, user: other_user)
      duplicate.instance_variable_set(:@new_record, true)

      expect do
        described_class.connection.execute(
          'INSERT INTO smart_folder_shares (id, smart_folder_id, user_id, can_edit, can_share, created_at, updated_at) ' \
          "VALUES ('#{SecureRandom.uuid}', '#{smart_folder.id}', '#{other_user.id}', false, false, NOW(), NOW())"
        )
      end.to raise_error(ActiveRecord::StatementInvalid, /unique/i)
    end
  end
end
