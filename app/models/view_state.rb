# frozen_string_literal: true

# == Schema Information
#
# Table name: view_states
#
#  id              :uuid             not null, primary key
#  key             :string           not null
#  state           :jsonb
#  viewable_type   :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  organisation_id :uuid             not null
#  user_id         :uuid             not null
#  viewable_id     :uuid             not null
#
# Indexes
#
#  index_view_states_on_key              (key)
#  index_view_states_on_organisation_id  (organisation_id)
#  index_view_states_on_user_id          (user_id)
#  index_view_states_on_viewable         (viewable_type,viewable_id)
#  index_view_states_unique              (user_id,key,viewable_type,viewable_id,organisation_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (user_id => users.id)
#
class ViewState < ApplicationRecord
  acts_as_tenant :organisation

  belongs_to :user
  belongs_to :viewable, polymorphic: true
  belongs_to :organisation

  validates :key, presence: true
  validates :key, uniqueness: { scope: %i[user_id viewable_type viewable_id organisation_id] }
  validate :state_must_be_a_hash

  # Reads a value at the given dot-separated path.
  # Returns nil if any intermediate key is missing or not a Hash.
  # Returns the full state hash if path is blank.
  def get_state(path)
    return state if path.blank?

    path.split('.').reduce(state) do |current, segment|
      current.is_a?(Hash) ? current[segment] : nil
    end
  end

  # Sets a value at the given dot-separated path, creating intermediate
  # hashes as needed, and saves the record.
  # Returns true/false based on save result.
  def set_state(path, value)
    raise ArgumentError, 'path must be present' if path.blank?

    self.state ||= {}
    keys = path.split('.')
    last_key = keys.pop

    target = keys.reduce(state) do |hash, segment|
      hash[segment] = {} unless hash[segment].is_a?(Hash)
      hash[segment]
    end

    target[last_key] = value
    save
  end

  # Finds or creates a ViewState for the given user, key, and viewable.
  # Uses the current tenant as organisation.
  # Handles race conditions from the unique index.
  def self.for_user_and_viewable(user, key, viewable)
    find_or_create_by(
      user: user,
      key: key,
      viewable: viewable,
      organisation: ActsAsTenant.current_tenant
    )
  rescue ActiveRecord::RecordNotUnique
    find_by!(
      user: user,
      key: key,
      viewable: viewable,
      organisation: ActsAsTenant.current_tenant
    )
  end

  private

  def state_must_be_a_hash
    errors.add(:state, :invalid) unless state.is_a?(Hash)
  end
end
