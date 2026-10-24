# frozen_string_literal: true

# Resolves the object an activity on the project feed is about. Project-scoped
# creation events hang on the project itself and keep the created object in the
# secondary association; ordinary changes hang directly on their object.
module Activities
  class ProjectTarget
    SECONDARY_ACTIONS = %w[
      ticket_created ticket_moved_in ticket_moved_out
      document_added document_created note_created chat_created
      meeting_created meeting_moved_in smart_folder_created
    ].freeze

    def self.call(activity)
      SECONDARY_ACTIONS.include?(activity.action) ? activity.secondary : activity.trackable
    end
  end
end
