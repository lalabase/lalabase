# frozen_string_literal: true

module Actors
  # A retry is a new, separately reviewable attempt at the original fixed target.
  class RetryTicketSuggestionRun < BaseActor
    def initialize(run:, current_user:)
      super()
      @run = run
      @current_user = current_user
    end

    def record
      @post
    end

    def perform
      @post = @run.chatpost.chat.chatposts.create!(organisation: @run.organisation, user: @current_user,
                                                   content: @run.instruction)
      result = StartTicketSuggestionRun.call(meeting: @run.meeting, chatpost: @post, current_user: @current_user, retry_of: @run)
      raise ActorError, result.errors unless result.success?
    end
  end
end
