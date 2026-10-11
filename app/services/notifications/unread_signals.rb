# frozen_string_literal: true

# The org switcher signal: "something needs you in another organisation".
#
# Counts the user's unread notifications per organisation with the inbox's own
# rule (Notification.inbox_unread): the number next to an organisation is the
# number its inbox shows after the switch. Until 29.09.2026 only mentions and
# assignments counted, and users could not tell why a comment in another
# organisation left no trace. The inbox count stays strictly per organisation
# (Notifications::Streams); this is the one deliberately cross-organisation
# signal, shown as a dot on the switcher and as a number next to each
# organisation in its menu.
#
# Live updates: a broadcaster cannot know which organisation a page shows, so
# .call renders one view per organisation, each without itself, and sends
# it to that organisation's badge stream.
#
# Who calls .refresh_later: Notification's after_commit (create, state change,
# destroy of an in-app notification) and Notification.bulk_transition!, the one
# way to change states in bulk (update_all skips that callback).
module Notifications
  class UnreadSignals
    class << self
      def signal?(notification)
        notification.channel_in_app?
      end

      # { organisation_id => count } for the user's active organisations
      # except `except`, positive counts only.
      def counts_for(user, except:)
        organisations = user.active_organisations.where.not(id: except).to_a
        count_by_organisation(user, organisations)
      end

      def refresh_later(user)
        Notifications::UnreadSignalsJob.perform_later(user_id: user.respond_to?(:id) ? user.id : user)
      end

      # Sum of `counts` for the organisations the switcher menu does not list
      # (it stops at NavigationHelper::ORG_MENU_LIMIT); shown on "Alle
      # Organisationen" so a hit beyond the menu still has a number to find.
      def overflow_count(counts, menu_ids)
        counts.except(*menu_ids).values.sum
      end

      # Entry point (service convention): recompute and broadcast for `user`.
      def call(user:)
        organisations = user.active_organisations.by_name.to_a
        return if organisations.size < 2

        counts = count_by_organisation(user, organisations)
        # Same order and cap as NavigationHelper#switcher_organisations.
        menu_ids = organisations.first(NavigationHelper::ORG_MENU_LIMIT).map(&:id)
        I18n.with_locale(user.language_preference.presence || I18n.default_locale) do
          organisations.each do |organisation|
            others = organisations.map(&:id) - [organisation.id]
            own_counts = counts.slice(*others)
            Turbo::StreamsChannel.broadcast_render_to(
              Notifications::Streams.badge(user, organisation),
              partial: 'notifications/other_orgs_signal_streams',
              locals: { counts: own_counts, organisation_ids: others & menu_ids,
                        overflow_count: overflow_count(own_counts, menu_ids) }
            )
          end
        end
      end

      private

      # One grouped query over all organisations; the access filter
      # (Notification.inbox_unread, the one inbox rule) runs only in an
      # organisation where that query found something.
      def count_by_organisation(user, organisations)
        return {} if organisations.empty?

        candidates = ActsAsTenant.without_tenant do
          Notification.where(recipient: user, organisation_id: organisations.map(&:id))
                      .channel_in_app.unread.group(:organisation_id).count
        end

        organisations.each_with_object({}) do |organisation, counts|
          next unless candidates[organisation.id].to_i.positive?

          count = signal_count_in_organisation(user, organisation)
          counts[organisation.id] = count if count.positive?
        end
      end

      # Project access answers per organisation by construction, so this runs
      # once per organisation that has candidates (allow-listed in
      # spec/support/prosopite.rb, like aggregate_org_slice).
      def signal_count_in_organisation(user, organisation)
        ActsAsTenant.with_tenant(organisation) do
          Notification.inbox_unread(user, organisation).count
        end
      end
    end
  end
end
