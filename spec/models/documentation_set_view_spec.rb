# frozen_string_literal: true

# == Schema Information
#
# Table name: documentation_set_views
#
#  id                   :uuid             not null, primary key
#  last_viewed_at       :datetime         not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  documentation_set_id :uuid             not null
#  organisation_id      :uuid             not null
#  user_id              :uuid             not null
#
# Indexes
#
#  idx_doc_set_views_set_user                             (documentation_set_id,user_id) UNIQUE
#  index_documentation_set_views_on_documentation_set_id  (documentation_set_id)
#  index_documentation_set_views_on_organisation_id       (organisation_id)
#  index_documentation_set_views_on_user_id               (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (documentation_set_id => documentation_sets.id)
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
require 'rails_helper'

# What: DocumentationSetView — per-user "last visited" marker uniqueness.
# Type: Model spec.
# Why:  One marker per user+set backs the "changed since last visit" badges
#       (DT5); a duplicate would double-count or mask changes.
RSpec.describe DocumentationSetView, type: :model do
  let(:organisation) { create(:organisation) }
  let(:set) { create(:documentation_set, project: create(:project, organisation: organisation)) }

  before { ActsAsTenant.current_tenant = organisation }

  describe 'validations' do
    it 'is valid with the factory' do
      expect(build(:documentation_set_view, documentation_set: set)).to be_valid
    end

    it 'requires last_viewed_at' do
      expect(build(:documentation_set_view, documentation_set: set, last_viewed_at: nil)).not_to be_valid
    end

    it 'is unique per user and set' do
      user = create(:user)
      create(:documentation_set_view, documentation_set: set, user: user)
      expect(build(:documentation_set_view, documentation_set: set, user: user)).not_to be_valid
    end

    it 'allows the same user on a different set' do
      user = create(:user)
      create(:documentation_set_view, documentation_set: set, user: user)
      other_set = create(:documentation_set, project: create(:project, organisation: organisation))
      expect(build(:documentation_set_view, documentation_set: other_set, user: user)).to be_valid
    end
  end

  # Defense in depth: the (documentation_set_id, user_id) unique index holds even
  # if the model validation is bypassed.
  describe 'DB-level uniqueness' do
    it 'raises RecordNotUnique when the model validation is skipped' do
      user = create(:user)
      create(:documentation_set_view, documentation_set: set, user: user)
      dup = build(:documentation_set_view, documentation_set: set, user: user)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe '.record_visit!' do
    let(:user) { create(:user) }

    it 'creates the marker on the first visit' do
      expect do
        described_class.record_visit!(documentation_set: set, user: user, organisation: organisation)
      end.to change(described_class, :count).by(1)

      expect(described_class.find_by(documentation_set: set, user: user).last_viewed_at).to be_present
    end

    it 'moves the existing marker forward instead of creating a second row' do
      create(:documentation_set_view, documentation_set: set, user: user, last_viewed_at: 2.days.ago)

      expect do
        described_class.record_visit!(documentation_set: set, user: user, organisation: organisation)
      end.not_to change(described_class, :count)

      expect(described_class.find_by(documentation_set: set, user: user).last_viewed_at)
        .to be > 1.minute.ago
    end

    it 'quietly loses the race when a concurrent request inserted the marker first' do
      racing_view = set.documentation_set_views.new(user: user)
      # Simulate the DB-level loser of two concurrent first visits: the unique
      # index rejects our insert because the other request committed first.
      racing_view.define_singleton_method(:save!) { raise ActiveRecord::RecordNotUnique, 'duplicate key' }
      allow(described_class).to receive(:find_or_initialize_by).and_return(racing_view)

      expect do
        described_class.record_visit!(documentation_set: set, user: user, organisation: organisation)
      end.not_to raise_error
    end
  end

  # FK on_delete: :cascade — the disposable marker is dropped with the user.
  describe 'user hard-delete' do
    it 'is deleted when its user is hard-deleted' do
      user = create(:user)
      create(:documentation_set_view, documentation_set: set, user: user)

      expect { user.delete }.to change(DocumentationSetView, :count).by(-1)
    end
  end
end
