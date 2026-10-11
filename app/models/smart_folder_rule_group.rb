# frozen_string_literal: true

# app/models/smart_folder_rule_group.rb
# == Schema Information
#
# Table name: smart_folder_rule_groups
#
#  id              :uuid             not null, primary key
#  name            :string
#  position        :integer          default(1), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  smart_folder_id :uuid             not null
#
# Indexes
#
#  index_smart_folder_rule_groups_on_smart_folder_id               (smart_folder_id)
#  index_smart_folder_rule_groups_on_smart_folder_id_and_position  (smart_folder_id,position)
#
# Foreign Keys
#
#  fk_rails_...  (smart_folder_id => smart_folders.id)
#
class SmartFolderRuleGroup < ApplicationRecord
  belongs_to :smart_folder, inverse_of: :smart_folder_rule_groups

  has_many :smart_folder_rules, -> { order(position: :asc) }, dependent: :destroy, inverse_of: :smart_folder_rule_group
  accepts_nested_attributes_for :smart_folder_rules, allow_destroy: true, reject_if: :all_blank

  validates :smart_folder, presence: true
  # Position is now set via a callback, but the validation does no harm
  validates :position, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1 }

  # Optional description for better readability
  validates :name, length: { maximum: 255 }, allow_blank: true

  # Sets the position automatically when it is not present
  before_validation :set_default_position, on: :create
  # Ensures the positions are reordered after deletion (optional, depending on the requirement)
  # after_destroy :reorder_positions

  # Indicates whether this group contains rules
  def has_rules?
    smart_folder_rules.any?
  end

  # Returns the number of rules in this group
  def rules_count
    smart_folder_rules.count
  end

  # Returns a human-readable description of the group
  def description
    return name if name.present?

    if has_rules?
      # Uses the description method of the rules
      rule_descriptions = smart_folder_rules.map(&:description).join(' UND ')
      "#{rule_descriptions}"
    else
      'Leere Regelgruppe'
    end
  end

  private

  # Sets the default position based on existing groups in the same smart folder
  def set_default_position
    return unless smart_folder && position.blank?

    max_position = smart_folder.smart_folder_rule_groups.maximum(:position) || 0
    self.position = max_position + 1
  end

  # Optional: reorder the positions of other groups when one is deleted
  # def reorder_positions
  #   return unless smart_folder
  #   smart_folder.smart_folder_rule_groups.order(:position).each_with_index do |group, index|
  #     group.update_column(:position, index + 1) if group.position != index + 1
  #   end
  # end
end
