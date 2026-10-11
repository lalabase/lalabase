# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SoftDeletable, type: :concern do
  # Use the actual User model for testing the concern
  let(:user) { create(:user) }

  describe 'scopes' do
    let!(:active_user) { create(:user, email: 'active@example.com') }
    let!(:deleted_user) { create(:user, email: 'deleted@example.com', deleted_at: 1.day.ago) }

    describe '.deleted' do
      it 'returns only soft-deleted records' do
        expect(User.deleted).to contain_exactly(deleted_user)
      end
    end

    describe '.with_deleted' do
      it 'returns all records including soft-deleted ones' do
        expect(User.with_deleted).to contain_exactly(active_user, deleted_user)
      end
    end

    describe '.only_deleted' do
      it 'returns only soft-deleted records' do
        expect(User.only_deleted).to contain_exactly(deleted_user)
      end
    end

    describe 'default scope behavior' do
      it 'excludes soft-deleted records by default' do
        expect(User.all).to contain_exactly(active_user)
      end
    end
  end

  describe '#soft_delete!' do
    it 'sets deleted_at timestamp' do
      expect { user.soft_delete! }.to change { user.reload.deleted_at }.from(nil)
    end

    it 'persists the deletion timestamp' do
      user.soft_delete!
      expect(user.reload.deleted_at).to be_within(1.second).of(Time.current)
    end

    it 'does not physically delete the record' do
      user.soft_delete!
      expect { user.reload }.not_to raise_error
    end
  end

  describe '#restore!' do
    before { user.update!(deleted_at: 1.day.ago) }

    it 'clears the deleted_at timestamp' do
      expect { user.restore! }.to change { user.reload.deleted_at }.to(nil)
    end

    it 'makes the record findable again' do
      user.restore!
      expect(User.find(user.id)).to eq(user)
    end
  end

  describe '#deleted?' do
    context 'when record is not soft-deleted' do
      it 'returns false' do
        expect(user.deleted?).to be false
      end
    end

    context 'when record is soft-deleted' do
      before { user.update!(deleted_at: 1.day.ago) }

      it 'returns true' do
        expect(user.deleted?).to be true
      end
    end
  end

  describe 'database constraints' do
    it 'allows deleted_at to be null' do
      expect { user.update!(deleted_at: nil) }.not_to raise_error
    end

    it 'allows deleted_at to be a timestamp' do
      timestamp = 1.day.ago
      expect { user.update!(deleted_at: timestamp) }.not_to raise_error
      expect(user.reload.deleted_at).to be_within(1.second).of(timestamp)
    end
  end
end
