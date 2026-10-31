# frozen_string_literal: true

module Notifications
  # Bundles constants for the notification system, in particular for the
  # mapping of activities to OutboxEvent types.
  module Constants
    # Event type constants (for type-safe referencing)
    EVENT_TYPE_TICKET_COMMENTED = 'ticket_commented'
    EVENT_TYPE_TICKET_CREATED = 'ticket_created'
    EVENT_TYPE_TICKET_ASSIGNED = 'ticket_assigned'
    EVENT_TYPE_TICKET_UNASSIGNED = 'ticket_unassigned'
    EVENT_TYPE_TICKET_STATUS_CHANGED = 'ticket_status_changed'
    EVENT_TYPE_TICKET_BLOCKER = 'ticket_blocker'
    EVENT_TYPE_PROJECT_ANNOUNCEMENT = 'project_announcement'
    EVENT_TYPE_DOCUMENT_ADDED = 'document_added'
    EVENT_TYPE_MENTION = 'mention'
    EVENT_TYPE_SYSTEM_MESSAGE = 'system_message'
    # Project-aware-chat M9-5: code-index outcome notifications.
    EVENT_TYPE_INDEX_COMPLETED = 'index_completed'
    EVENT_TYPE_INDEX_FAILED = 'index_failed'
    # One event for a bulk change of several tickets (doc/ticket_bulk_edit_plan.md, D4)
    EVENT_TYPE_TICKETS_BULK_CHANGED = 'tickets_bulk_changed'
    # A bulk move and a bulk delete say what happened (slice 7)
    EVENT_TYPE_TICKETS_BULK_MOVED = 'tickets_bulk_moved'
    EVENT_TYPE_TICKETS_BULK_DELETED = 'tickets_bulk_deleted'

    # Valid event types, which must match the database enum.
    VALID_EVENT_TYPES = [
      EVENT_TYPE_TICKET_COMMENTED,
      EVENT_TYPE_TICKET_ASSIGNED,
      EVENT_TYPE_TICKET_UNASSIGNED,
      EVENT_TYPE_TICKET_STATUS_CHANGED,
      EVENT_TYPE_TICKET_BLOCKER,
      EVENT_TYPE_PROJECT_ANNOUNCEMENT,
      EVENT_TYPE_DOCUMENT_ADDED,
      EVENT_TYPE_MENTION,
      EVENT_TYPE_SYSTEM_MESSAGE,
      EVENT_TYPE_INDEX_COMPLETED,
      EVENT_TYPE_INDEX_FAILED,
      EVENT_TYPE_TICKETS_BULK_CHANGED,
      EVENT_TYPE_TICKETS_BULK_MOVED,
      EVENT_TYPE_TICKETS_BULK_DELETED
    ].freeze

    # Defines which events should be delivered immediately by default
    IMMEDIATE_DELIVERY_EVENTS = [
      EVENT_TYPE_MENTION,
      EVENT_TYPE_TICKET_ASSIGNED,
      EVENT_TYPE_TICKET_BLOCKER,
      EVENT_TYPE_TICKET_COMMENTED
    ].freeze

    # Defines which activity keys and actions lead to which notification event type.
    # The keys (`activity.key`) take precedence over the actions (`activity.action`).
    EVENT_TYPE_MAPPING = {
      # Activity keys (higher priority)
      'ticket.created' => EVENT_TYPE_SYSTEM_MESSAGE, # Changed: ticket creation should not trigger assignment notification
      'ticket.updated' => EVENT_TYPE_TICKET_STATUS_CHANGED,
      'ticket.assigned' => EVENT_TYPE_TICKET_ASSIGNED,
      'ticket.unassigned' => EVENT_TYPE_TICKET_UNASSIGNED,
      'ticket.status_changed' => EVENT_TYPE_TICKET_STATUS_CHANGED,
      'ticket.priority_changed' => EVENT_TYPE_TICKET_BLOCKER,
      'ticket.commented' => EVENT_TYPE_TICKET_COMMENTED,
      'ticket.ticket_commented' => EVENT_TYPE_TICKET_COMMENTED,
      'post.created' => EVENT_TYPE_TICKET_COMMENTED,
      'project.announcement' => EVENT_TYPE_PROJECT_ANNOUNCEMENT,
      'project.note_created' => EVENT_TYPE_DOCUMENT_ADDED,
      'project.updated' => EVENT_TYPE_PROJECT_ANNOUNCEMENT,
      'project.member_added' => EVENT_TYPE_PROJECT_ANNOUNCEMENT,
      'project.tickets_bulk_changed' => EVENT_TYPE_TICKETS_BULK_CHANGED,
      'project.tickets_bulk_undone' => EVENT_TYPE_TICKETS_BULK_CHANGED,
      'project.tickets_bulk_moved' => EVENT_TYPE_TICKETS_BULK_MOVED,
      'project.tickets_bulk_moved_in' => EVENT_TYPE_TICKETS_BULK_MOVED,
      'project.tickets_bulk_deleted' => EVENT_TYPE_TICKETS_BULK_DELETED,
      'document.created' => EVENT_TYPE_DOCUMENT_ADDED,
      'note.created' => EVENT_TYPE_DOCUMENT_ADDED,
      'mention.created' => EVENT_TYPE_MENTION,

      # Activity actions (Fallback)
      'post_added' => EVENT_TYPE_TICKET_COMMENTED,
      'post_created' => EVENT_TYPE_TICKET_COMMENTED,
      'comment_added' => EVENT_TYPE_TICKET_COMMENTED,
      'ticket_commented' => EVENT_TYPE_TICKET_COMMENTED,
      'ticket_created' => EVENT_TYPE_TICKET_ASSIGNED,
      'ticket_updated' => EVENT_TYPE_TICKET_STATUS_CHANGED,
      'ticket_assigned' => EVENT_TYPE_TICKET_ASSIGNED,
      'document_added' => EVENT_TYPE_DOCUMENT_ADDED,
      'note_added' => EVENT_TYPE_DOCUMENT_ADDED,
      'note_created' => EVENT_TYPE_DOCUMENT_ADDED,
      'member_added' => EVENT_TYPE_PROJECT_ANNOUNCEMENT,
      'updated' => EVENT_TYPE_PROJECT_ANNOUNCEMENT,
      'mentioned' => EVENT_TYPE_MENTION,
      'created' => EVENT_TYPE_SYSTEM_MESSAGE,
      'assigned' => EVENT_TYPE_TICKET_ASSIGNED,
      'unassigned' => EVENT_TYPE_TICKET_UNASSIGNED,
      'deleted' => EVENT_TYPE_SYSTEM_MESSAGE,
      'archived' => EVENT_TYPE_SYSTEM_MESSAGE
    }.freeze

    # Icon mappings for event types
    EVENT_TYPE_ICONS = {
      EVENT_TYPE_TICKET_COMMENTED => 'chat-left-text',
      EVENT_TYPE_TICKET_ASSIGNED => 'person-plus',
      EVENT_TYPE_TICKET_UNASSIGNED => 'person-dash',
      EVENT_TYPE_TICKET_STATUS_CHANGED => 'arrow-right-circle',
      EVENT_TYPE_TICKET_BLOCKER => 'exclamation-triangle',
      EVENT_TYPE_PROJECT_ANNOUNCEMENT => 'megaphone',
      EVENT_TYPE_DOCUMENT_ADDED => 'file-earmark-plus',
      EVENT_TYPE_MENTION => 'at',
      EVENT_TYPE_SYSTEM_MESSAGE => 'info-circle',
      EVENT_TYPE_TICKETS_BULK_CHANGED => 'collection',
      EVENT_TYPE_TICKETS_BULK_MOVED => 'arrow-right-square',
      EVENT_TYPE_TICKETS_BULK_DELETED => 'trash',
      EVENT_TYPE_INDEX_COMPLETED => 'check-circle',
      EVENT_TYPE_INDEX_FAILED => 'exclamation-octagon'
    }.freeze

    DEFAULT_ICON = 'bell'

    # Payload pattern mappings for event type inference
    PAYLOAD_PATTERN_MAPPINGS = {
      # Payload keys that indicate certain event types
      %w[post_excerpt comment] => 'ticket_commented',
      %w[status_change] => 'ticket_status_changed',
      %w[assignment] => 'ticket_assigned'
    }.freeze

    # Event type to mailer action mappings for EmailDeliveryJob
    EVENT_TYPE_TO_MAILER_ACTION = {
      EVENT_TYPE_TICKET_COMMENTED => 'ticket_comment',
      EVENT_TYPE_TICKET_ASSIGNED => 'ticket_assignment',
      EVENT_TYPE_TICKET_UNASSIGNED => 'ticket_unassignment',
      EVENT_TYPE_TICKET_STATUS_CHANGED => 'ticket_status_changed',
      EVENT_TYPE_TICKET_BLOCKER => 'ticket_blocker',
      EVENT_TYPE_PROJECT_ANNOUNCEMENT => 'project_announcement',
      EVENT_TYPE_DOCUMENT_ADDED => 'document_added',
      EVENT_TYPE_MENTION => 'mention',
      EVENT_TYPE_SYSTEM_MESSAGE => 'system_message',
      EVENT_TYPE_INDEX_COMPLETED => 'index_completed',
      EVENT_TYPE_INDEX_FAILED => 'index_failed',
      EVENT_TYPE_TICKETS_BULK_CHANGED => 'tickets_bulk_changed',
      EVENT_TYPE_TICKETS_BULK_MOVED => 'tickets_bulk_changed',
      EVENT_TYPE_TICKETS_BULK_DELETED => 'tickets_bulk_changed'
    }.freeze

    DEFAULT_MAILER_ACTION = 'generic_notification'

    # Email subject templates for event types
    EMAIL_SUBJECT_TEMPLATES = {
      EVENT_TYPE_TICKET_COMMENTED => 'New comment on %<title>s',
      EVENT_TYPE_TICKET_ASSIGNED => 'Ticket assigned: %<title>s',
      EVENT_TYPE_TICKET_UNASSIGNED => 'Ticket unassigned: %<title>s',
      EVENT_TYPE_TICKET_STATUS_CHANGED => 'Ticket updated: %<title>s',
      EVENT_TYPE_TICKET_BLOCKER => 'Priority changed: %<title>s',
      EVENT_TYPE_MENTION => 'You were mentioned in %<title>s',
      EVENT_TYPE_PROJECT_ANNOUNCEMENT => 'Project announcement: %<title>s',
      EVENT_TYPE_DOCUMENT_ADDED => 'New document: %<title>s',
      EVENT_TYPE_SYSTEM_MESSAGE => 'System notification: %<title>s',
      EVENT_TYPE_INDEX_COMPLETED => 'Code index ready: %<title>s',
      EVENT_TYPE_INDEX_FAILED => 'Code index failed: %<title>s'
    }.freeze

    DEFAULT_EMAIL_SUBJECT = 'New notification from %<organization>s'

    # Channel constants
    CHANNEL_EMAIL = 'email'
    CHANNEL_IN_APP = 'in_app'

    # Event type to color mappings for UI components
    EVENT_TYPE_COLORS = {
      EVENT_TYPE_TICKET_ASSIGNED => 'primary',
      EVENT_TYPE_TICKET_UNASSIGNED => 'warning',
      EVENT_TYPE_MENTION => 'primary',
      EVENT_TYPE_TICKET_BLOCKER => 'danger',
      EVENT_TYPE_PROJECT_ANNOUNCEMENT => 'info',
      EVENT_TYPE_TICKET_STATUS_CHANGED => 'success',
      EVENT_TYPE_TICKET_COMMENTED => 'secondary',
      EVENT_TYPE_DOCUMENT_ADDED => 'secondary',
      EVENT_TYPE_SYSTEM_MESSAGE => 'secondary',
      EVENT_TYPE_INDEX_COMPLETED => 'success',
      EVENT_TYPE_INDEX_FAILED => 'danger',
      EVENT_TYPE_TICKETS_BULK_CHANGED => 'success',
      EVENT_TYPE_TICKETS_BULK_MOVED => 'info',
      EVENT_TYPE_TICKETS_BULK_DELETED => 'danger'
    }.freeze

    DEFAULT_EVENT_COLOR = 'secondary'

    # Priority constants
    PRIORITY_HIGH = 'high'
    PRIORITY_CRITICAL = 'critical'
    PRIORITY_NORMAL = 'normal'
    PRIORITY_LOW = 'low'

    HIGH_PRIORITY_VALUES = [PRIORITY_HIGH, PRIORITY_CRITICAL].freeze

    # State to CSS class mappings for UI components
    NOTIFICATION_STATE_CLASSES = {
      'read' => 'bg-gray-50',
      'archived' => 'bg-gray-100 opacity-75',
      'queued' => 'bg-white',
      'sent' => 'bg-white',
      'delivered' => 'bg-white'
    }.freeze

    DEFAULT_STATE_CLASS = 'bg-white'

    # Priority to CSS class mappings
    PRIORITY_INDICATOR_CLASSES = {
      PRIORITY_HIGH => 'w-1 h-full bg-orange-400 absolute left-0 top-0 rounded-l-lg',
      PRIORITY_CRITICAL => 'w-1 h-full bg-red-500 absolute left-0 top-0 rounded-l-lg'
    }.freeze

    # Notification status constants
    STATE_QUEUED = 'queued'
    STATE_SENT = 'sent'
    STATE_DELIVERED = 'delivered'
    STATE_READ = 'read'
    STATE_ARCHIVED = 'archived'

    # Subscription mode constants
    SUBSCRIPTION_MODE_IMMEDIATE = 'immediate'
    SUBSCRIPTION_MODE_FOLLOW = 'follow'
    SUBSCRIPTION_MODE_MUTE = 'mute'

    # Legacy subscription levels (for backward compatibility)
    SUBSCRIPTION_LEVEL_WATCHING = 'watching'
    SUBSCRIPTION_LEVEL_NORMAL = 'normal'
    SUBSCRIPTION_LEVEL_MUTED = 'muted'

    # High-engagement subscription values
    HIGH_ENGAGEMENT_MODES = [SUBSCRIPTION_MODE_IMMEDIATE, SUBSCRIPTION_LEVEL_WATCHING].freeze
    NORMAL_ENGAGEMENT_MODES = [SUBSCRIPTION_MODE_FOLLOW, SUBSCRIPTION_LEVEL_NORMAL].freeze
    MUTED_MODES = [SUBSCRIPTION_MODE_MUTE, SUBSCRIPTION_LEVEL_MUTED].freeze

    # Explicit overrides for event type derivation.
    # Only exceptions that cannot be derived convention-based.
    # Everything else is auto-derived via keyword matching (see .derive_event_type).
    EXPLICIT_EVENT_TYPE_OVERRIDES = {
      # A bulk run of several tickets is its own event (doc/ticket_bulk_edit_plan.md, D4);
      # by keyword it would read as a project announcement.
      'project.tickets_bulk_changed' => EVENT_TYPE_TICKETS_BULK_CHANGED,
      'project.tickets_bulk_undone' => EVENT_TYPE_TICKETS_BULK_CHANGED,
      'project.tickets_bulk_moved' => EVENT_TYPE_TICKETS_BULK_MOVED,
      'project.tickets_bulk_moved_in' => EVENT_TYPE_TICKETS_BULK_MOVED,
      'project.tickets_bulk_deleted' => EVENT_TYPE_TICKETS_BULK_DELETED,
      # Activity keys - special cases
      'ticket.created' => EVENT_TYPE_SYSTEM_MESSAGE,
      'ticket.updated' => EVENT_TYPE_TICKET_STATUS_CHANGED,
      'ticket.ticket_commented' => EVENT_TYPE_TICKET_COMMENTED,
      'post.created' => EVENT_TYPE_TICKET_COMMENTED,
      'project.note_created' => EVENT_TYPE_DOCUMENT_ADDED,
      # Project news like project.updated. The action fallback below would make it a
      # system message: score 80 and more, so a mail at once to every account admin.
      'project.created' => EVENT_TYPE_PROJECT_ANNOUNCEMENT,
      'mention.created' => EVENT_TYPE_MENTION,
      'ticket.moved' => EVENT_TYPE_SYSTEM_MESSAGE,

      # Activity actions - legacy fallbacks
      'ticket_created' => EVENT_TYPE_TICKET_ASSIGNED,
      'ticket_updated' => EVENT_TYPE_TICKET_STATUS_CHANGED,
      'member_added' => EVENT_TYPE_PROJECT_ANNOUNCEMENT,
      'created' => EVENT_TYPE_SYSTEM_MESSAGE,
      'deleted' => EVENT_TYPE_SYSTEM_MESSAGE,
      'archived' => EVENT_TYPE_SYSTEM_MESSAGE
    }.freeze

    # Central method for deriving the event type from an activity key and action.
    # Replaces the 4 identical copies in FanoutService, Suppressor, ScoreCalculator, OutboxEvent.
    #
    # Strategy:
    # 1. Check explicit overrides (key takes precedence over action)
    # 2. Convention-based auto-derive via keyword matching
    # 3. Fallback to system_message
    def self.derive_event_type(key, action = nil)
      # Step 1: Explicit overrides (key takes precedence)
      return validate_event_type(EXPLICIT_EVENT_TYPE_OVERRIDES[key]) if key.present? && EXPLICIT_EVENT_TYPE_OVERRIDES.key?(key)
      return validate_event_type(EXPLICIT_EVENT_TYPE_OVERRIDES[action]) if action.present? && EXPLICIT_EVENT_TYPE_OVERRIDES.key?(action)

      # Step 2: Convention-based auto-derive
      derived = auto_derive_event_type(key, action)
      return validate_event_type(derived) if derived

      # Step 3: Fallback
      EVENT_TYPE_SYSTEM_MESSAGE
    end

    # Auto-derive via keyword matching on key + action.
    # IMPORTANT: "unassign" must be checked BEFORE "assign"!
    def self.auto_derive_event_type(key, action)
      combined = [key, action].compact.join(' ')
      return nil if combined.blank?

      if combined.match?(/comment|post|repl(?:y|ied)/)
        EVENT_TYPE_TICKET_COMMENTED
      elsif combined.include?('unassign')
        EVENT_TYPE_TICKET_UNASSIGNED
      elsif combined.include?('assign')
        EVENT_TYPE_TICKET_ASSIGNED
      elsif combined.include?('status')
        EVENT_TYPE_TICKET_STATUS_CHANGED
      elsif combined.include?('priority') || combined.include?('blocker')
        EVENT_TYPE_TICKET_BLOCKER
      elsif combined.include?('mention')
        EVENT_TYPE_MENTION
      elsif combined.include?('document') || combined.include?('note')
        EVENT_TYPE_DOCUMENT_ADDED
      elsif key&.start_with?('project.')
        EVENT_TYPE_PROJECT_ANNOUNCEMENT
      end
    end

    def self.validate_event_type(type)
      return type if VALID_EVENT_TYPES.include?(type)

      Rails.logger.warn "Notifications::Constants: Invalid event type '#{type}', using system_message"
      EVENT_TYPE_SYSTEM_MESSAGE
    end
  end
end
