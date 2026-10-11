# frozen_string_literal: true

# app/services/actors/share_smart_folder.rb
#
# Shares a SmartFolder with a set of users, all-or-nothing: either every share is
# created (in one transaction) or none is. The caller (controller) is responsible
# for IDOR-rescoping `users` to the shareable set — this actor trusts the relation
# it is handed. A partial mix ("3 shared, 1 failed") is intentionally impossible.

module Actors
  class ShareSmartFolder < BaseActor
    def initialize(smart_folder:, users:, current_user:, can_edit: false, can_share: false)
      super()
      @smart_folder = smart_folder
      @users = users
      @current_user = current_user
      @options = { can_edit: can_edit, can_share: can_share }
      @count = 0
    end

    def record
      @smart_folder
    end

    # Number of shares created (owner is never counted). Read after #call.
    attr_reader :count

    def perform
      @users.each do |user|
        # The owner can never be shared with; shareable_users already excludes
        # them, this is belt-and-suspenders.
        next if user.id == @smart_folder.user_id

        raise ActorError, "share_with failed for user #{user.id}" unless @smart_folder.share_with(user, @options)

        @count += 1
      end
    end
  end
end
