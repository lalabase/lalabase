# frozen_string_literal: true

# app/services/actors/destroy_chat.rb
#
# Destroys a chat with all of its posts in one transaction, via the plain
# `dependent: :destroy` cascade. The cascade destroys every chatpost WITH
# `destroyed_by_association` set, so the system-post guard in Chatpost#destroy
# is skipped and each post's callbacks still run. Replaces the old controller
# loop whose inner rescue swallowed a mid-loop RecordInvalid and committed the
# already-destroyed posts (partial delete) — under BaseActor#call any failure
# propagates out of #perform and rolls the whole delete back.

module Actors
  class DestroyChat < BaseActor
    def initialize(chat:, current_user:)
      super()
      @chat = chat
      @current_user = current_user
    end

    # A destroy leaves no surviving primary record.
    def record
      nil
    end

    def perform
      @chat.destroy!
    end
  end
end
