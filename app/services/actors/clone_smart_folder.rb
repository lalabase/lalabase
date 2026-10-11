# frozen_string_literal: true

# app/services/actors/clone_smart_folder.rb
#
# Deep-copies a SmartFolder (folder attributes + rule groups + rules) into a new
# folder owned by current_user. Shares are intentionally NOT copied and the copy
# starts fully private (is_public: false AND public_access_level: 0) — dup carries
# the source's public_access_level verbatim, so it must be reset explicitly, else a
# later "make public" would inherit the source's access level. The name defaults to
# "Kopie von <source>" unless an explicit new_name is given.

module Actors
  class CloneSmartFolder < BaseActor
    def initialize(source:, current_user:, new_name: nil)
      super()
      @source = source
      @current_user = current_user
      @new_name = new_name
      @clone = nil
    end

    def record
      @clone
    end

    def perform
      @clone = @source.dup
      @clone.assign_attributes(user: @current_user, is_public: false, public_access_level: 0, name: clone_name)
      @clone.save!

      copy_rule_groups
    end

    private

    # dup copies only the folder's own columns; rebuild the association tree by
    # hand. Both associations carry a default position order, so preloading the
    # source rules keeps the copy ordered and avoids an N+1 across groups.
    def copy_rule_groups
      source_groups = @source.smart_folder_rule_groups.includes(:smart_folder_rules).to_a
      source_groups.each do |group|
        @clone.smart_folder_rule_groups.create!(
          name: group.name,
          position: group.position,
          smart_folder_rules_attributes: group.smart_folder_rules.map { |rule| rule_copy_attributes(rule) }
        )
      end
    end

    def rule_copy_attributes(rule)
      rule.slice(:field, :operator, :value, :display_value, :config, :position)
    end

    def clone_name
      @new_name.presence || I18n.t('smart_folders.copy_of', name: @source.name)
    end
  end
end
