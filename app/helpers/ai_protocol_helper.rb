# frozen_string_literal: true

# View helper for the AI protocol page (doc/ki_bereich_navigation_plan.md S5).
module AiProtocolHelper
  # Overrides for Activity#message that turn the stored tier KEYS into the labels the
  # rest of the app shows.
  #
  # The asymmetry is in the writer: Actors::SelectAiPackage#choice_parameters stores the
  # two packages as LABELS ('from_package'/'to_package') but the two tiers as KEYS. The
  # sentence therefore read 'Leistungsstufe von "fast" auf "thorough" gewechselt', while
  # the settings page calls the same rungs "Schnell & günstig" and "Gründlich".
  #
  # Repaired here rather than at the writer on purpose: entries written before today
  # already exist and cannot be rewritten, and Activity#message merges its options OVER
  # the stored parameters, so one call fixes old and new rows alike.
  #
  # Resolution order, narrowest first: the rung as this package actually names it (an
  # operator may have renamed it), then the shipped default, then the raw key — which is
  # still an honest answer for a package that has since been deleted.
  #
  # @return [Hash] empty for every entry that carries no tier keys, so the caller can
  #   splat it unconditionally.
  def tier_labels(entry)
    parameters = entry.parameters || {}
    %w[from_tier_key to_tier_key].each_with_object({}) do |field, overrides|
      key = parameters[field]
      next if key.blank?

      overrides[field.to_sym] = tier_label_for(entry.secondary, key)
    end
  end

  private

  def tier_label_for(package, key)
    package_label = package.respond_to?(:tier_for) ? package.tier_for(key)&.label : nil
    package_label.presence || AiPackageTier::DEFAULT_LABELS[key].presence || key
  end
end
