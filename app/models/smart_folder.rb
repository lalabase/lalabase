# frozen_string_literal: true

# app/models/smart_folder.rb
# == Schema Information
#
# Table name: smart_folders
#
#  id                  :uuid             not null, primary key
#  color_code          :integer
#  description         :text
#  display_columns     :jsonb
#  is_public           :boolean          default(FALSE)
#  name                :string           not null
#  position            :integer
#  public_access_level :integer          default(0)
#  sort_by             :integer          default(0)
#  sort_column         :string
#  sort_direction      :string
#  target_object_type  :string           default("Note")
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  organisation_id     :uuid             not null
#  project_id          :uuid
#  user_id             :uuid             not null
#
# Indexes
#
#  index_smart_folders_on_organisation_id                         (organisation_id)
#  index_smart_folders_on_organisation_id_and_is_public           (organisation_id,is_public)
#  index_smart_folders_on_organisation_id_and_project_id          (organisation_id,project_id)
#  index_smart_folders_on_organisation_id_and_target_object_type  (organisation_id,target_object_type)
#  index_smart_folders_on_organisation_id_and_user_id             (organisation_id,user_id)
#  index_smart_folders_on_project_id                              (project_id)
#  index_smart_folders_on_user_id                                 (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (organisation_id => organisations.id)
#  fk_rails_...  (project_id => projects.id)
#  fk_rails_...  (user_id => users.id)
#
class SmartFolder < ApplicationRecord
  # Optional: a folder without a project spans the organisation. Declared
  # BEFORE acts_as_tenant on purpose: acts_as_tenant only checks the
  # belongs_to associations it already knows, and this check is what refuses
  # a project id of another organisation from the form.
  belongs_to :project, optional: true
  acts_as_tenant(:organisation)
  belongs_to :user
  belongs_to :organisation

  has_many :smart_folder_rule_groups, -> { order(position: :asc) }, dependent: :destroy, inverse_of: :smart_folder
  has_many :smart_folder_rules, through: :smart_folder_rule_groups # Convenience association
  has_many :smart_folder_shares, dependent: :destroy, inverse_of: :smart_folder
  has_many :shared_users, through: :smart_folder_shares, source: :user

  # Define the supported object types
  SUPPORTED_OBJECT_TYPES = {
    'Note' => 'Notizen',
    'Ticket' => 'Tickets',
    'Document' => 'Dokumente',
    'Meeting' => 'Meetings',
    'TimeSession' => 'Zeitsitzungen',
    'All' => 'Alle Objekttypen'
  }.freeze

  # Preserve the type contract of existing mixed views; Meeting is an explicit target.
  ALL_OBJECT_TYPES = %w[Note Ticket Document TimeSession].freeze

  # Use nested attributes to handle our dynamically created rule groups and rules
  accepts_nested_attributes_for :smart_folder_rule_groups,
                                allow_destroy: true,
                                reject_if: :reject_empty_destroyed_group?

  # Upper bounds of a rule tree. Several values of one filter category become
  # one group each, and several such categories multiply; the bounds keep a
  # saved view a query the database can answer. AdHocToSmartFolderService
  # checks them before it builds the groups, #rule_tree_within_bounds guards
  # the expert editor.
  MAX_RULE_GROUPS = 50
  MAX_RULES_PER_GROUP = 50

  def smart_folder_rule_groups_attributes=(attributes)
    @rule_tree_assigned = true
    super
  end

  # Permitted sort columns
  VALID_SORT_COLUMNS = %w[updated_at created_at title number occurred_at duration_minutes].freeze

  # 255 matches the rename field's maxlength (the filter bar's tab menu); the
  # column itself has no limit, so a crafted request would otherwise store any length.
  validates :name, presence: true, length: { maximum: 255 }
  validates :organisation, presence: true
  validates :user, presence: true
  validates :target_object_type, presence: true, inclusion: { in: SUPPORTED_OBJECT_TYPES.keys }
  validates :sort_column, inclusion: { in: VALID_SORT_COLUMNS }, allow_nil: true
  validates :sort_direction, inclusion: { in: %w[asc desc] }, allow_nil: true
  # ⚠️ An allowlist: a new key has to be admitted HERE before it can be written.
  # pinned_columns joined it on 07.09.2026; without that the save came back
  # "Konnte nicht speichern", which is all a validation failure looks like from
  # the column picker's side - the reason stood only in the log.
  #
  # A CONSTANT and not a literal in the validation, so a spec can iterate it:
  # a negative test proves nothing about the keys that are supposed to work, and
  # a hardcoded list in the spec would just be the same mistake written twice.
  DISPLAY_COLUMN_KEYS = %w[table_columns pinned_columns list_columns header_columns].freeze

  validate :validate_display_columns_structure, if: -> { display_columns.present? }
  validate :rule_tree_within_bounds, if: -> { @rule_tree_assigned }

  # Sort options for displaying the results
  # Disabled until the migration has been run
  # enum sort_by: {
  #   updated_desc: 0,      # Most recently updated (default)
  #   updated_asc: 1,       # Updated earliest first
  #   created_desc: 2,      # Newest first
  #   created_asc: 3,       # Oldest first
  #   title_asc: 4,         # Alphabetical A-Z
  #   title_desc: 5         # Alphabetical Z-A
  # }, _prefix: :sort # Prefix avoids name collisions

  # Access levels for public folders
  # Disabled until the migration has been run
  # enum public_access_level: {
  #   view_only: 0,  # View only
  #   use_rules: 1,  # Reuse rules in one's own folders
  #   copy: 2        # Copying allowed
  # }, _prefix: :public # Prefix avoids name collisions

  # Temporary methods that replace the enum functionality
  def sort_by_name
    case sort_by
    when 0 then 'updated_desc'
    when 1 then 'updated_asc'
    when 2 then 'created_desc'
    when 3 then 'created_asc'
    when 4 then 'title_asc'
    when 5 then 'title_desc'
    else 'updated_desc'
    end
  end

  def public_access_level_name
    case public_access_level
    when 0 then 'view_only'
    when 1 then 'use_rules'
    when 2 then 'copy'
    else 'view_only'
    end
  end

  def public_copy?
    public_access_level == 2
  end

  # --- Display configuration (doc/spaltenwahl_plan.md, D1 and D6) ---

  # The folder's own ordered columns, or nil when it has none and follows the
  # reader's base view. One list, the same shape as
  # ViewConfiguration#ordered_columns; the old second list under
  # `list_columns` (cells, and fields below the title) is folded in behind it
  # until the next write of the hash replaces it.
  def ordered_columns
    return nil unless custom_columns?

    ViewConfiguration.normalize_columns(
      Array(display_columns['table_columns']) + ViewConfiguration.legacy_list_extras(display_columns['list_columns']), column_view_type
    )
  end

  # The ONE writer: the hash becomes the list alone, so the legacy second
  # list under list_columns goes with the first save (D1).
  def ordered_columns=(keys)
    self.display_columns = self.class.display_columns_for(keys, view_type: column_view_type)
  end

  def column_view_type
    target_object_type == 'Meeting' ? 'meetings' : 'tickets'
  end

  # The stored shape of a column list, for the writer above and for a bulk
  # write over many folders (Actors::ApplyColumnsToViews). The pins ride in the
  # same hash: they belong to the view, exactly like the list and its order.
  def self.display_columns_for(keys, pinned: nil, view_type: 'tickets')
    { 'table_columns' => ViewConfiguration.normalize_columns(keys, view_type) }.tap do |hash|
      hash['pinned_columns'] = Array(pinned).map(&:to_s).uniq - ViewConfiguration::ALWAYS_PINNED if pinned
    end
  end

  # Which of this folder's columns stay readable when the width runs out. nil
  # (not []) when the folder has no list of its own - then the reader's base
  # view answers, pins and all.
  def pinned_column_keys
    return nil unless custom_columns?

    Array(display_columns['pinned_columns']).map(&:to_s)
  end

  def pinned_column_keys=(keys)
    self.display_columns = self.class.display_columns_for(
      Array(display_columns['table_columns']), pinned: keys, view_type: column_view_type
    )
  end

  # A folder with a column list of its own.
  def custom_columns?
    display_columns.is_a?(Hash) && display_columns.present?
  end

  # --- Sorting (prefer the new fields, fall back to the sort_by integer) ---

  def effective_sort_column
    sort_column.presence || (target_object_type == 'Meeting' ? 'occurred_at' : sort_by_to_column)
  end

  def effective_sort_direction
    sort_direction.presence || sort_by_to_direction
  end

  # Delegate the complex logic to the service
  # Ensures the current user is passed in, if available.
  def results(current_user_context = nil)
    SmartFolderService.new(self, current_user_context || user).fetch_results
  end

  # Checks whether a user has access to this folder (simplified, since the policy handles this)
  def accessible_by?(user_to_check)
    return false unless user_to_check

    Pundit.policy(user_to_check, self).show?
  end

  # Checks whether a user may edit this folder (simplified, since the policy handles this)
  def editable_by?(user_to_check)
    return false unless user_to_check

    Pundit.policy(user_to_check, self).update?
  end

  # Adds a new user to the share list
  def share_with(user_to_share, options = {})
    return false unless user_to_share
    return false if user_to_share.id == user_id
    return false unless user_to_share.organisations.include?(organisation)

    share = smart_folder_shares.find_or_initialize_by(user_id: user_to_share.id)
    share.can_edit = options.fetch(:can_edit, share.can_edit || false) # Keep the old value or set the default
    share.can_share = options.fetch(:can_share, share.can_share || false)
    share.save
  end

  # Removes a user from the share list
  def unshare_with(user_to_unshare)
    return false unless user_to_unshare

    smart_folder_shares.where(user_id: user_to_unshare.id).destroy_all
  end

  # Returns the number of rules (optimized)
  def rules_count
    # Uses the through-association for a more efficient count
    smart_folder_rules.count
  end

  # Returns the number of rule groups
  def groups_count
    smart_folder_rule_groups.count
  end

  private

  # Runs only after the expert editor assigned a rule tree: the groups load
  # once (stored and submitted merged), the stored rule counts in one query.
  def rule_tree_within_bounds
    groups = smart_folder_rule_groups.reject(&:marked_for_destruction?)
    return errors.add(:base, :too_many_rule_groups, count: MAX_RULE_GROUPS) if groups.size > MAX_RULE_GROUPS

    stored = SmartFolderRule.where(smart_folder_rule_group_id: groups.select(&:persisted?).map(&:id))
                            .group(:smart_folder_rule_group_id).count
    return unless groups.any? { |group| rule_count(group, stored) > MAX_RULES_PER_GROUP }

    errors.add(:base, :too_many_rules, count: MAX_RULES_PER_GROUP)
  end

  def rule_count(group, stored)
    submitted = group.association(:smart_folder_rules).target
    stored.fetch(group.id, 0) + submitted.count(&:new_record?) -
      submitted.count { |rule| rule.persisted? && rule.marked_for_destruction? }
  end

  # Checks whether a destroyed rule group with no surviving rules can be skipped.
  def reject_empty_destroyed_group?(attributes)
    attributes['_destroy'] == '1' &&
      (attributes['smart_folder_rules_attributes'].blank? ||
       attributes['smart_folder_rules_attributes'].values.all? { |r| r['_destroy'] == '1' })
  end

  def sort_by_to_column
    case sort_by
    when 0, 1 then 'updated_at'
    when 2, 3 then 'created_at'
    when 4, 5 then 'title'
    else 'updated_at'
    end
  end

  def sort_by_to_direction
    case sort_by
    when 1, 3, 4 then 'asc'
    else 'desc'
    end
  end

  def validate_display_columns_structure
    unless display_columns.is_a?(Hash)
      errors.add(:display_columns, :not_a_hash)
      return
    end

    invalid_keys = display_columns.keys - DISPLAY_COLUMN_KEYS
    errors.add(:display_columns, :invalid_keys, keys: invalid_keys.join(', ')) if invalid_keys.any?

    errors.add(:display_columns, :table_columns_not_array) if display_columns['table_columns'].present? && !display_columns['table_columns'].is_a?(Array)

    errors.add(:display_columns, :pinned_columns_not_array) if display_columns['pinned_columns'].present? && !display_columns['pinned_columns'].is_a?(Array)

    errors.add(:display_columns, :header_columns_not_array) if display_columns['header_columns'].present? && !display_columns['header_columns'].is_a?(Array)

    return unless display_columns['list_columns'].present?
    return if display_columns['list_columns'].is_a?(Hash)

    errors.add(:display_columns, :list_columns_invalid)
  end
end
