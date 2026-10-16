# frozen_string_literal: true

# app/services/actors/save_smart_folder_from_filters.rb
#
# The ONE persistence path for turning ad-hoc list filters into a SmartFolder.
# Serves both create (smart_folder: nil → new folder) and update
# (smart_folder: given → keep the folder, replace its rule tree). Conversion of
# the raw filter params into rule attributes is delegated to the pure
# AdHocToSmartFolderService; this actor owns the transaction and the writes.

module Actors
  class SaveSmartFolderFromFilters < BaseActor
    # columns: the ordered column list a NEW folder starts with (doc/spaltenwahl_plan.md,
    # D6); nil leaves it following the reader's base view. Ignored on update, the
    # save row has its own endpoint for a folder's columns.
    # project: nil for a view of a list of the whole organisation ("Alle Meetings");
    # the folder then belongs to no project, and organisation names its owner.
    def initialize(project:, current_user:, filter_params:, operator_params:, name:,
                   organisation: project&.organisation, smart_folder: nil, sort_column: nil,
                   sort_direction: nil, target_object_type: 'Ticket', columns: nil, pinned_columns: nil)
      super()
      @project = project
      @organisation = organisation
      @current_user = current_user
      @filter_params = filter_params
      @operator_params = operator_params
      @name = name
      @smart_folder = smart_folder
      @sort_column = sort_column
      @sort_direction = sort_direction
      @target_object_type = target_object_type
      @columns = columns
      @pinned_columns = pinned_columns
    end

    def record
      @smart_folder
    end

    def perform
      conversion = convert_filters

      ensure_complete_meeting_conversion!(conversion)

      if @smart_folder
        # Update: keep the folder, replace its rule tree. The lock serialises
        # concurrent saves, and the check after it reads the tree that is
        # actually replaced, not the one the request started from.
        @smart_folder.lock!
        ensure_replaceable_meeting_rules!
        @smart_folder.smart_folder_rule_groups.destroy_all
      else
        @smart_folder = create_folder
      end

      persist_rules(conversion)
    end

    private

    # A set of conditions beyond the rule tree bounds is refused before any
    # write; the caller shows the message (code :rule_tree_too_large).
    def convert_filters
      AdHocToSmartFolderService.call(
        project: @project,
        organisation: @organisation,
        filter_params: @filter_params,
        operator_params: @operator_params,
        target_object_type: @smart_folder&.target_object_type || @target_object_type
      )
    rescue AdHocToSmartFolderService::RuleTreeTooLarge => e
      raise ActorError.new(e.message, code: :rule_tree_too_large)
    end

    def ensure_complete_meeting_conversion!(conversion)
      return unless (@smart_folder&.target_object_type || @target_object_type) == 'Meeting'

      requested = @filter_params.select { |_key, values| Array(values).any?(&:present?) }.keys.map(&:to_s)
      converted = conversion.rules_by_group.flatten.map { |rule| rule[:field] }.uniq
      return if conversion.warnings.empty? && (requested - converted).empty?

      raise ActorError.new(I18n.t('flash.smart_folders.update_from_filters_error'), code: :validation_failed)
    end

    # Chips may only replace a Meeting rule tree the filter bar can show. An
    # expert rule saved while this request waited for the lock must survive.
    def ensure_replaceable_meeting_rules!
      return unless @smart_folder.target_object_type == 'Meeting'
      return if SmartFolderDissolver.new(@smart_folder, @current_user).call.dissolvable?

      raise ActorError.new(I18n.t('flash.smart_folders.update_from_filters_error'), code: :validation_failed)
    end

    def create_folder
      folder = SmartFolder.new(
        project: @project,
        name: @name,
        user: @current_user,
        organisation: @organisation,
        target_object_type: @target_object_type,
        sort_column: @sort_column,
        sort_direction: @sort_direction
      )
      folder.ordered_columns = @columns if @columns.present?
      folder.pinned_column_keys = @pinned_columns if @pinned_columns
      folder.save!
      folder
    end

    def persist_rules(conversion)
      conversion.rules_by_group.each_with_index do |group_rules, idx|
        group = @smart_folder.smart_folder_rule_groups.create!(position: idx + 1)
        group_rules.each_with_index do |rule_attrs, rule_idx|
          SmartFolderRuleFactory.build(
            group,
            rule_attrs[:field],
            rule_attrs[:operator],
            rule_attrs[:value],
            rule_idx + 1,
            field_config_map: conversion.field_config_map,
            preloaded_references: conversion.preloaded_references
          ).save!
        end
      end
    end
  end
end
