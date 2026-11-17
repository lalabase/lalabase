# frozen_string_literal: true

module Api
  module Auth
    module V1
      # GET /api/auth/v1/methods: what this instance offers for signing in, asked
      # by a client before it sends a password anywhere. An older instance has no
      # such route; a client reads every answer without data.sign_in.methods as
      # "this sign-in does not exist here".
      #
      # It goes to everybody, so it names no version and no instance. The links
      # are the pages a person needs when the sign-in fails; a client opens them
      # in a browser.
      class MethodsController < BaseController
        PASSWORD = 'password'

        def show
          render json: {
            data: {
              sign_in: { methods: Lalabase::Demo.enabled? ? [] : [PASSWORD] },
              links: {
                password_reset: new_user_password_path,
                unlock: new_user_unlock_path,
                confirmation: new_user_confirmation_path
              }
            }
          }
        end

        private

        # Answers in the demo too, with no method: a client then offers none.
        def answers_in_demo?
          true
        end
      end
    end
  end
end
