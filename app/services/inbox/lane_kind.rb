# frozen_string_literal: true

# What a row of the inbox opens in the lane beside the list.
#
# Entry point: for
#
# The one owner of the question both inboxes used to ask as `notifiable.is_a?(Ticket)` in
# seven places (the lane's loader, the row, the page above the organisations, the answers
# of a row action). The kind of a row is decided by its EVENT, not by the type of its
# subject: a notification is filed under what its activity was tracked on, which is the
# ticket or the PROJECT, and a new note or document is an event on the project whose object
# is the activity's secondary (Activities::ProjectTarget). There is no notification about a
# note.
#
# `for` answers nil for a subject the lane does not know (a person, a time session group, a
# repository, an old row filed under a note): such a row keeps leaving for its full view.
# For a ticket and for a project it answers a value that says what the lane draws:
#
#   body :inline  the ticket, rendered by the inbox itself as before
#   body :frame   an object with a display of its own: the lane holds
#                 turbo-frame#ticket_display_frame with `frame_path` as its src, and the
#                 object's own controller draws it under its own policy (Inbox::ObjectFrame)
#   body :card    an event without a display (a new member), or one whose object is gone
#
# Nothing is read until it is asked for: the list asks `for` once per row and loads nothing
# (above the organisations a row has no tenant, and a read there raises). The lane asks
# `target`, which reads the activity the payload names and its object, inside the tenant of
# the row's organisation. Rights are not decided here: the row is visible by the policy
# scope of the notifications, and the loader asks the object's own policy before it draws.
module Inbox
  class LaneKind
    Entry = Struct.new(:key, :body, keyword_init: true)

    # How the lane shows an object, by its class. Closed and fail-closed, like
    # Assistant::PanelRegistry: a class without an entry has no display, and the class is
    # looked up, never built from a name.
    REGISTRY = {
      # The subject of a ticket notification. A ticket that arrives through a project event
      # (created, moved in or out) keeps the card until the lane takes those rows too.
      Ticket => Entry.new(key: 'ticket', body: :inline).freeze,
      # The object of a project event, drawn by its own controller.
      Note => Entry.new(key: 'note', body: :frame).freeze,
      # The subject of every project event; as the object of one (a new member, a changed
      # right) it has no display, the event gets a card.
      Project => Entry.new(key: 'project', body: :card).freeze
    }.freeze

    # The events whose card has a text of its own
    # (views.organisations.notifications.pane.event_card.<action>). Every other event gets
    # the default card.
    WORDED_CARDS = %w[
      member_added member_removed permission_changed updated
      note_created document_created meeting_created meeting_deleted
    ].freeze
    DEFAULT_CARD = 'default'
    # The object of the event was deleted, or the activity that names it is gone (retention).
    GONE_CARD = 'gone'

    def self.for(notification)
      entry = REGISTRY[notification&.notifiable.class]
      # A frame entry is the object of an event, never the subject a row is filed under.
      return if entry.nil? || entry.body == :frame

      new(notification: notification)
    end

    attr_reader :notification

    def initialize(notification:)
      @notification = notification
    end

    # The object the lane is about: the ticket, or what the project's event is about. Nil
    # when the event names an object that no longer exists.
    def target
      return @target if defined?(@target)

      @target = project_event? ? event_object : subject
    end

    def body
      return :inline unless project_event?

      target_entry&.body == :frame && frame_address ? :frame : :card
    end

    # The address the lane's frame loads, for an object with a display of its own.
    def frame_path
      frame_address if body == :frame
    end

    # The address of the object's own page, for the head's link "open full view".
    def full_path
      return if body == :card

      ObjectFrame.full_path(target, organisation: notification.organisation_id, project: target.project_id)
    end

    # The key of the event card, or nil when the lane shows an object.
    def card
      return unless body == :card
      return GONE_CARD if gone?

      WORDED_CARDS.include?(action) ? action : DEFAULT_CARD
    end

    def gone?
      project_event? && target.nil?
    end

    # Where the card leads: the object's own page while it exists and has one, else the
    # project. [what the link names, its address].
    def card_link
      return unless body == :card

      object_page = ObjectFrame.full_path(target, organisation: notification.organisation_id, project: project&.id) if worded_object?
      return [target.class.name.underscore.to_sym, object_page] if object_page

      [:project, Rails.application.routes.url_helpers.organisation_project_path(notification.organisation_id, subject)]
    end

    # The project the lane's head names.
    def project
      body == :card ? subject : target.project
    end

    # The word for what the lane shows ("ticket", "note"), for the head's texts. Nil for a card.
    def type_key
      target_entry.key unless body == :card
    end

    private

    def subject
      notification.notifiable
    end

    def project_event?
      subject.is_a?(Project)
    end

    def action
      (activity&.action || notification.payload['action']).to_s
    end

    # What the event is about (Activities::ProjectTarget): the project itself, or the object
    # in the activity's secondary. Without the activity an event that names an object has
    # lost it; an event about the project still has its subject.
    def event_object
      return Activities::ProjectTarget.call(activity) if activity

      Activities::ProjectTarget::SECONDARY_ACTIONS.include?(action) ? nil : subject
    end

    # The activity the notification reports, when it is one of this project. Read inside
    # the tenant of the row's organisation.
    def activity
      return @activity if defined?(@activity)

      id = notification.payload['activity_id']
      @activity = id.present? ? Activity.find_by(id: id, trackable_type: 'Project', trackable_id: subject.id) : nil
    end

    def target_entry
      REGISTRY[target.class]
    end

    def frame_address
      return @frame_address if defined?(@frame_address)

      @frame_address = ObjectFrame.path(target, organisation: notification.organisation_id, project: target.try(:project_id))
    end

    # The card names an object of its own (a meeting, until the lane shows one): its page is
    # where the card leads. The project and a ticket are not such objects.
    def worded_object?
      target && !REGISTRY.key?(target.class) && WORDED_CARDS.include?(action)
    end
  end
end
