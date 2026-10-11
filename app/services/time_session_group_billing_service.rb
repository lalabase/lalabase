# frozen_string_literal: true

class TimeSessionGroupBillingService
  class << self
    # Marks a TimeSessionGroup and all associated time sessions as billed
    def mark_as_billed(group, invoice_number:, billed_at: Time.current)
      ActiveRecord::Base.transaction do
        # Update the group
        group.update!(
          billed: true,
          invoice_number: invoice_number,
          billed_at: billed_at
        )

        # Update all associated time sessions
        group.time_sessions.update_all(
          billed: true,
          billed_at: billed_at,
          invoice_number: invoice_number
        )

        group
      end
    end

    # Marks a TimeSessionGroup and all associated time sessions as not billed
    def mark_as_unbilled(group)
      ActiveRecord::Base.transaction do
        # Update the group
        group.update!(
          billed: false,
          invoice_number: nil,
          billed_at: nil
        )

        # Update all associated time sessions
        group.time_sessions.update_all(
          billed: false,
          billed_at: nil,
          invoice_number: nil
        )

        group
      end
    end

    # Adds a TimeSession to a group and takes over the billed status
    def add_time_session_to_group(time_session, group)
      ActiveRecord::Base.transaction do
        time_session.update!(
          time_session_group: group,
          billed: group.billed?
        )

        time_session
      end
    end

    # Removes a TimeSession from a group
    def remove_time_session_from_group(time_session)
      return time_session unless time_session.time_session_group

      # Actors::ActorError is defined as a load side-effect of base_actor.rb
      # (not Zeitwerk-autoloadable) — force the load so a cold call (console/
      # rake after a fresh boot, no actor touched yet) raises the coded error
      # below instead of a NameError.
      Actors::BaseActor.name

      # Prevent removal from billed groups. Coded error (T3, plan §9.8-3): the
      # SaveTimeSession actor pre-checks this, so the raise is a parity guard
      # for non-actor callers — no bare StandardError behind the actor seam
      # (with_error_mapping would turn it into :internal_error).
      if time_session.billed?
        raise Actors::ActorError.new(I18n.t('services.save_time_session.session_billed'),
                                     code: :session_billed)
      end

      ActiveRecord::Base.transaction do
        time_session.update!(
          time_session_group: nil,
          billed: false
        )

        time_session
      end
    end

    # Synchronizes the billed status of all time sessions in a group
    # Useful for data repair or after manual changes
    def sync_billed_status(group)
      ActiveRecord::Base.transaction do
        group.time_sessions.update_all(billed: group.billed?)
      end
    end

    # Checks the consistency between the group and its sessions
    def check_consistency(group)
      inconsistent_sessions = group.time_sessions.where(billed: !group.billed?)

      if inconsistent_sessions.exists?
        {
          consistent: false,
          message: "Found #{inconsistent_sessions.count} inconsistent time sessions",
          session_ids: inconsistent_sessions.pluck(:id)
        }
      else
        {
          consistent: true,
          message: 'All time sessions are consistent with group billing status'
        }
      end
    end
  end
end
