# frozen_string_literal: true

# app/models/smart_folder_share.rb
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
class SmartFolderShare < ApplicationRecord
  # Tenant isolation happens indirectly via smart_folder.organisation (no own acts_as_tenant needed,
  # since access always goes through smart_folder.smart_folder_shares or policy-secured paths).
  belongs_to :smart_folder, inverse_of: :smart_folder_shares
  belongs_to :user

  validates :user_id, uniqueness: { scope: :smart_folder_id }
  validate :not_sharing_with_owner

  private

  def not_sharing_with_owner
    return unless user.present? && smart_folder.present? && user_id == smart_folder.user_id

    errors.add(:user_id, :cannot_share_with_owner)
  end
end
