# frozen_string_literal: true

# app/services/actors/change_notification_states.rb
#
# One action on a SELECTION of inbox rows: read or archive. The ONE write
# behind the bulk bar of the inbox of an organisation
# (Organisations::NotificationsController, its path with ids) and of the inbox
# above the organisations (AllInboxesController). The action on a single row is
# Actors::ChangeNotificationState.
#
# The caller has found the rows through its own gate and hands them over per
# organisation ({ organisation => [ids] }). The actor reads them again, under
# the lock, as rows the person may see in THAT organisation
# (Notifications::SubjectBundle): an id of another person, of another
# organisation, of a mail row or of a project lost in the meantime changes
# nothing and says nothing.
#
# Bundling: one ticket is one inbox row, so every in-app notification about the
# subject of a selected row goes along.
#
# One transaction over all organisations, worked through in the order of their
# ids and each under its own tenant: a failure in one rolls the others back.
# Both changes only touch what is not there yet (unread rows are read, rows
# outside the archive are archived), so a repeated request changes nothing.
module Actors
  class ChangeNotificationStates < BaseActor
    CHANGES = %w[read archive].freeze

    # How many notifications changed, siblings included.
    attr_reader :changed_count

    def initialize(ids_by_organisation:, change:, current_user:)
      super()
      @ids_by_organisation = ids_by_organisation
      @change = change.to_s
      @current_user = current_user
      @changed_count = 0
    end

    # A selection has no primary record.
    def record
      nil
    end

    def perform
      raise ActorError.new("unknown change #{@change}", code: :invalid_input) unless CHANGES.include?(@change)

      @changed_count = 0
      @ids_by_organisation.sort_by { |organisation, _ids| organisation.id }.each do |organisation, ids|
        @changed_count += change_states_in_organisation(organisation, ids)
      end
    end

    private

    attr_reader :current_user

    # Named so the loop per organisation has its own frame in the Prosopite stack
    # (spec/support/prosopite.rb): Notification is tenant-scoped and the rule of
    # what the person may see answers per organisation, so the same statements
    # repeat once for each organisation the selection touches.
    def change_states_in_organisation(organisation, ids)
      ActsAsTenant.with_tenant(organisation) { send(:"perform_#{@change}", locked_rows(organisation, ids)) }
    end

    # The selected in-app rows and their bundles, locked. A mail row is no row of
    # an inbox: it is neither changed nor does it bring its ticket along.
    def locked_rows(organisation, ids)
      visible = Notifications::SubjectBundle.visible(user: current_user, organisation: organisation)
      Notifications::SubjectBundle.lock(visible: visible, chosen: visible.channel_in_app.where(id: ids))
                                  .channel_in_app
    end

    def perform_read(rows)
      rows.unread.bulk_transition!(state: 'read', read_at: Time.current)
    end

    def perform_archive(rows)
      rows.where.not(state: Notification.states[:archived])
          .bulk_transition!(state: 'archived', archived_at: Time.current)
    end
  end
end
