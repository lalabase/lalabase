# frozen_string_literal: true

# app/services/actors/destroy_person.rb
#
# Deletes one row of the people directory. Rights are the caller's
# (PersonPolicy). The row's activities go with it; PersonTrackable leaves one
# anonymous person.deleted activity behind ("X deleted a person"), without a
# name or any other data of the row (D6).
module Actors
  class DestroyPerson < BaseActor
    def initialize(person:, current_user:)
      super()
      @person = person
      @current_user = current_user
    end

    # A destroy leaves no surviving primary record.
    def record
      nil
    end

    def perform
      @person.destroy!
    end

    private

    attr_reader :current_user
  end
end
