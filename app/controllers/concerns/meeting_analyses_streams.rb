# frozen_string_literal: true

# Shared turbo-stream builders for stored meeting analyses. The legacy creation
# endpoint remains deployment-compatible, but all current creation happens in the
# assistant and only the meeting's result list is a stream target. Assumes @meeting
# is set. can_write: true because the
# POST/DELETE is already server-authorized (mirrors the DocumentVersion _version_row
# pattern); the request-render path derives can_write from the policy instead.
module MeetingAnalysesStreams
  extend ActiveSupport::Concern

  private

  # Replace the results frame (freshly visibility-filtered for the acting user).
  def results_replace
    turbo_stream.replace(
      helpers.meeting_analyses_frame_id(@meeting),
      partial: 'organisations/meetings/analyses_results',
      locals: {
        meeting: @meeting,
        analyses: helpers.visible_meeting_analyses(@meeting),
        can_write: true
      }
    )
  end

  def flash_stream(flash_key, type: :notice)
    turbo_stream.prepend('flash', partial: 'layouts/flash', locals: { flash: { type => t(flash_key) } })
  end
end
