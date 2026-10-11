# frozen_string_literal: true

# What the bare domain answers.
#
# Until 20.09.2026 it redirected to /de, the German marketing page. On
# lalabase.com nginx never lets a request get this far, so that only ever
# showed on a SELF-HOSTED instance -- where it greeted visitors with our
# marketing, our pricing and our company name in the footer, on someone
# else's server (website split, W6).
#
# The bare domain of an application belongs to the application: whoever is
# signed in goes where they work, everybody else to the sign-in form.
class RootController < ApplicationController
  # The whole point is to answer a visitor who is NOT signed in.
  skip_before_action :authenticate_user!
  # No tenant is chosen yet, and user_home_path decides without one.
  skip_before_action :load_tenant_from_session

  def show
    return redirect_to user_home_path(current_user) if user_signed_in?

    redirect_to new_user_session_path
  end
end
