# frozen_string_literal: true

# THE lock for a meeting write in a controller action. The action was
# authorized against @project; a move (Actors::MoveMeeting) that committed
# meanwhile has taken the meeting into a project this request was never
# checked for. Such a meeting is gone from here: 404, as for a foreign one.
# The block runs inside the transaction that holds the meeting's row lock
# (Meeting#lock_in_project!). Guard: spec/architecture/meeting_lock_guard_spec.rb,
# which asks every write action of the meeting controllers for this call or
# for an actor that locks itself.
module MeetingInProject
  private

  def with_meeting_in_project(meeting = @meeting)
    Meeting.transaction do
      raise ActiveRecord::RecordNotFound unless meeting.lock_in_project!(@project.id)

      yield
    end
  end
end
