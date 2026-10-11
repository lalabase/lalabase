# frozen_string_literal: true

# Side-effect chain map: docs/architektur/seiteneffekt_ketten.md
module Trackable
  extend ActiveSupport::Concern

  # The context a write runs in, for every activity this record creates during
  # that write (doc/ticket_bulk_edit_plan.md, D4 and D12): a hash merged into
  # the activity's parameters (`bulk_run_id`, `skip_notifications`, which the
  # outbox and the fanout already read). nil means today's behaviour. Set by
  # the actor that owns the write, never by a model.
  attr_accessor :activity_context

  included do
    has_many :activities, as: :trackable, dependent: :destroy

    # Automatic tracking for standard actions
    after_create_commit :track_created, if: :track_activities?
    before_update :capture_rich_text_changes, if: :track_activities?
    after_update_commit :track_updated, if: :track_activities?
    before_destroy :track_deleted, if: :track_activities?
  end

  # Public API for manual activity tracking

  def create_activity(action:, secondary: nil, parameters: {}, attribute_changes: {})
    return unless track_activities?
    return unless activity_actor.present?

    context = (activity_context || {}).to_h.transform_keys(&:to_s)
    activities.create!(
      actor: activity_actor,
      organisation: organisation,
      action: action,
      secondary: secondary,
      parameters: enriched_parameters(parameters).to_h.transform_keys(&:to_s).merge(context),
      attribute_changes: attribute_changes
    )
  rescue StandardError => e
    Rails.logger.error "[Activity] Failed to create activity for #{self.class.name}##{id}: #{e.message}"
    Rails.logger.error "[Activity] Action: #{action}, Actor: #{activity_actor&.id}"
    # Activities should never block the main action
  end

  # Helper for specific activity types

  def track_association_added(association_name, associated_object, metadata = {})
    create_activity(
      action: "#{association_name.to_s.singularize}_added",
      secondary: associated_object,
      parameters: metadata
    )
  end

  def track_association_removed(association_name, associated_object, metadata = {})
    create_activity(
      action: "#{association_name.to_s.singularize}_removed",
      secondary: associated_object,
      parameters: metadata
    )
  end

  def track_attribute_change(attribute_name, from:, to:, metadata: {})
    create_activity(
      action: "#{attribute_name}_changed",
      attribute_changes: { attribute_name => [from, to] },
      parameters: metadata
    )
  end

  private

  # Override this method to disable activities
  def track_activities?
    true
  end

  # Override this method to set a different actor
  def activity_actor
    Current.user
  end

  # Override this method to add default parameters
  def enriched_parameters(params)
    params
  end

  # Standard Activity Callbacks

  def track_created
    create_activity(
      action: 'created',
      parameters: activity_parameters_for_create
    )
  end

  def track_updated
    # updater_id is bookkeeping, not content: the activity itself records the
    # actor. Recording it produced "Updater: <uuid>" detail rows (user report
    # 05.09.2026); Activity::NOISE_CHANGE_ATTRIBUTES filters historic data.
    changed_attrs = previous_changes.except('updated_at', 'created_at', 'updater_id')
    changed_attrs.merge!(@rich_text_changed_attrs || {})
    @rich_text_changed_attrs = nil
    return if changed_attrs.empty?

    # Special handlers for certain attributes
    if respond_to?(:track_specific_changes, true)
      track_specific_changes(changed_attrs)
    else
      # Generic update tracking
      create_activity(
        action: 'updated',
        attribute_changes: changed_attrs,
        parameters: activity_parameters_for_update
      )
    end
  end

  # A rich-text body (the ticket description) lives in its own ActionText
  # row, so editing it changes no column HERE: before 05.09.2026 a
  # description-only edit either left no trace at all (same editor) or a raw
  # "Updater: <uuid>" row (different editor). Captured DURING the save
  # (before_update), while the pending rich-text row still says whether THIS
  # save writes it - its previous_changes would stay sticky across later
  # saves of the parent. The value is nil on purpose: there is no old/new
  # pair worth storing for a body, the ACTION carries the meaning
  # (description_changed for tickets); Activity#formatted_changes skips
  # nil-valued entries.
  def capture_rich_text_changes
    changed = self.class.reflect_on_all_associations(:has_one).filter_map do |assoc|
      name = assoc.name.to_s
      next unless name.start_with?('rich_text_')
      next unless association(assoc.name).loaded?

      record = public_send(assoc.name)
      next unless record && (record.new_record? || record.body_changed?)

      name.delete_prefix('rich_text_')
    end
    @rich_text_changed_attrs = changed.index_with { nil }
  end

  def track_deleted
    create_activity(
      action: 'deleted',
      parameters: activity_parameters_for_delete
    )
  end

  # Override these methods for model-specific parameters

  def activity_parameters_for_create
    {
      display_name: try(:display_name) || try(:title) || try(:name)
    }
  end

  def activity_parameters_for_update
    {
      display_name: try(:display_name) || try(:title) || try(:name)
    }
  end

  def activity_parameters_for_delete
    {
      display_name: try(:display_name) || try(:title) || try(:name)
    }
  end
end
