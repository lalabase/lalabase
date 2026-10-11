# frozen_string_literal: true

module UserDataExports
  module Serializers
    # E-mail delivery metadata for the user. Dedicated class because there is
    # no user FK on email_logs: the reliable link is the notification join
    # (recipient_id); the recipient_email column is a legacy fallback only —
    # it is NOT populated by EmailLog.create_for_notification!, so matching by
    # address alone would return an almost empty history.
    #
    # Runs tenant-scoped (inside with_tenant) like every EmailLog query —
    # acts_as_tenant with require_tenant would raise otherwise.
    #
    # METADATA ONLY: bodies are full mail copies (DSGVO audit 1.3) and third
    # parties may appear in metadata — neither is exported.
    class EmailLogsSerializer
      ATTRIBUTES = %w[subject status sent_at delivered_at opened_at created_at].freeze

      def self.call(_source, user)
        rows = []
        scope(user).find_each(batch_size: 500) do |log|
          rows << ATTRIBUTES.index_with { |attr| log.public_send(attr) }
        end
        rows
      end

      def self.scope(user)
        by_notification = EmailLog.left_joins(:notification)
                                  .where(notifications: { recipient_id: user.id })
        by_legacy_email = EmailLog.left_joins(:notification)
                                  .where(recipient_email: user.email)
        by_notification.or(by_legacy_email).distinct
      end
    end
  end
end
