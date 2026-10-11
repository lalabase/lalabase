# frozen_string_literal: true

# Creates the first instance admin (Beuser) of a fresh installation, the one who can
# reach /admin. Called by `bin/rails lalabase:setup` (doc/oss_core_split_plan.md §8).
#
# Refuses once any Beuser exists: the task is a way in for an empty instance, not a
# second door into a running one. Everything after the first admin happens in /admin.
#
# `role` and `active` are both set here because the admin login demands both
# (Admin::SessionsController) and the column default of `active` is false.
module Setup
  class CreateFirstAdmin
    class Refused < StandardError; end

    # Beuser validates the same floor; checked here first for a plain refusal text.
    MINIMUM_PASSWORD_LENGTH = Beuser::MINIMUM_PASSWORD_LENGTH

    def self.call(**)
      new(**).call
    end

    def initialize(email:, password:)
      @email = email.to_s.strip
      @password = password.to_s
    end

    def call
      raise Refused, 'An admin exists already. Manage admins in /admin.' if Beuser.exists?
      raise Refused, 'Email is missing.' if @email.blank?
      raise Refused, "Password needs at least #{MINIMUM_PASSWORD_LENGTH} characters." if @password.length < MINIMUM_PASSWORD_LENGTH

      Beuser.create!(email: @email, password: @password, password_confirmation: @password,
                     role: 'admin', active: true)
    rescue ActiveRecord::RecordInvalid => e
      raise Refused, e.record.errors.full_messages.to_sentence
    end
  end
end
