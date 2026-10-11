# frozen_string_literal: true

# == Schema Information
#
# Table name: taggings
#
#  id            :uuid             not null, primary key
#  taggable_type :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  tag_id        :uuid             not null
#  taggable_id   :uuid             not null
#  user_id       :uuid
#
# Indexes
#
#  index_taggings_on_tag_and_type      (tag_id,taggable_type)
#  index_taggings_on_tag_id            (tag_id)
#  index_taggings_on_taggable          (taggable_type,taggable_id)
#  index_taggings_on_taggable_and_tag  (taggable_type,taggable_id,tag_id)
#  index_taggings_on_user_id           (user_id)
#  index_taggings_uniqueness           (tag_id,taggable_type,taggable_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (tag_id => tags.id)
#  fk_rails_...  (user_id => users.id)
#
class Tagging < ApplicationRecord
  # NOTE: acts_as_tenant is not set directly, as it causes problems with polymorphic joins.
  # Organisation scoping runs through the Tag model (Tag has acts_as_tenant).
  # Additionally, a validation ensures that the Tag and the Taggable
  # belong to the same organisation.

  belongs_to :tag
  belongs_to :taggable, polymorphic: true
  belongs_to :user, optional: true

  validates :tag_id, uniqueness: { scope: %i[taggable_id taggable_type] }
  validate :tag_belongs_to_same_organisation_as_taggable

  private

  def tag_belongs_to_same_organisation_as_taggable
    return unless tag && taggable
    return unless taggable.respond_to?(:organisation_id)

    return unless tag.organisation_id != taggable.organisation_id

    errors.add(:tag, :wrong_organisation)
  end
end
