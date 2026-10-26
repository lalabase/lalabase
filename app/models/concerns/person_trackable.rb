# frozen_string_literal: true

# Side-effect chain map: docs/architektur/seiteneffekt_ketten.md
#
# Tracking for the people directory WITHOUT personal data. A person row holds
# data about third parties (name, phone, notes), and activities outlive the row
# (Trackable#track_deleted runs after the row's own activities are gone and
# leaves one new row behind). So:
#
# * no activity carries a name or a value: the parameters are empty, and an
#   update keeps only the NAMES of the changed fields ("phone changed");
# * a delete leaves exactly one anonymous person.deleted row ("X deleted a
#   person"), the audit trail;
# * no activity fans out. skip_notifications is the default context, whoever
#   writes (actor, console, a later import): person.* has no entry in
#   notifications/constants.rb, and an unknown key would fall back to
#   system_message in the fanout. This differs from Trackable, where the actor
#   sets the context; a person write has nobody to tell, ever.
module PersonTrackable
  extend ActiveSupport::Concern

  include Trackable

  # The context every person activity carries unless a caller set its own; a
  # caller's context is merged on top and cannot switch the flag off.
  QUIET_CONTEXT = { 'skip_notifications' => true }.freeze

  # Bookkeeping columns, never shown as "changed".
  UNTRACKED_FIELDS = %w[lock_version normalized_name creator_id].freeze

  def activity_context
    (super || {}).to_h.transform_keys(&:to_s).merge(QUIET_CONTEXT)
  end

  private

  def track_specific_changes(changed_attrs)
    fields = changed_attrs.keys - UNTRACKED_FIELDS
    return if fields.empty?

    create_activity(action: 'updated', attribute_changes: fields.index_with { nil }, parameters: {})
  end

  def activity_parameters_for_create
    {}
  end

  def activity_parameters_for_update
    {}
  end

  def activity_parameters_for_delete
    {}
  end
end
