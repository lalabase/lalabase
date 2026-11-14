# frozen_string_literal: true

# The address of an object's own display inside turbo-frame#ticket_display_frame.
#
# Entry point: path
#
# A lane that shows an object of another area does not render it: it holds a frame whose
# `src` is this address, and the object's own controller draws the frame under its own
# policy (`frame=content`, `frame_id`). Two lanes do that, the project's activity page and
# the lane of the inbox (Inbox::LaneKind), and both ask here, so the list of objects that
# have such a display is written once.
module Inbox
  class ObjectFrame
    FRAME_ID = 'ticket_display_frame'

    # The route of an object's page, by its class. Closed: a class without a route has no
    # display, and the caller shows what it shows without one.
    ROUTES = {
      Ticket => :organisation_project_ticket_path,
      Document => :organisation_project_document_path,
      Note => :organisation_project_note_path,
      Meeting => :organisation_project_meeting_path,
      TimeSession => :organisation_project_time_session_path
    }.freeze

    # The address the lane's frame loads, or nil.
    def self.path(target, organisation:, project:)
      full_path(target, organisation: organisation, project: project, frame: 'content', frame_id: FRAME_ID)
    end

    # The address of the object's own page, or nil.
    def self.full_path(target, organisation:, project:, **query)
      route = ROUTES[target.class]
      return unless route && organisation && project

      Rails.application.routes.url_helpers.public_send(route, organisation, project, target, **query)
    end
  end
end
