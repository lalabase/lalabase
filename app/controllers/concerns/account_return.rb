# frozen_string_literal: true

# The way out of the account area (navigation plan D5, Belegungstabelle F44): on an account
# page (NavigationHelper::ACCOUNT_PAGES) the sidebar shows "Zurück", which leads to the page
# the reader came from, inside an organisation or on the level above them
# (NavigationHelper#account_return_path).
#
# That page is the referer of the first account page, kept as a path in the session
# (ReturnPath). A page opened from another account page keeps what is there, so the way back
# survives moving through the account. Entering the area from anywhere else replaces it: with
# a referer of this host that is a page, by its path; without one (a typed address, a new tab,
# a foreign host, a path too long) by nothing, and "Zurück" leads to the reader's home.
#
# Only a full page counts (ApplicationController#full_page_request?, the predicate the
# session's organisation follows): a frame load, a stream and a write keep nothing.
module AccountReturn
  extend ActiveSupport::Concern
  include ReturnPath

  SESSION_KEY = :account_return_path

  included do
    before_action :remember_account_return
  end

  private

  # NavigationHelper.account_page?, not `helpers`: a before_action must not build the view
  # context (it would keep the view assigns of this moment).
  def remember_account_return
    return unless user_signed_in? && full_page_request?
    return unless NavigationHelper.account_page?(controller_name)

    uri = same_host_referer
    return if uri && account_referer?(uri.path)

    path = return_path_of(uri) if uri && controller_name_of(uri.path)
    if ReturnPath.path?(path)
      session[SESSION_KEY] = path
    else
      session.delete(SESSION_KEY)
    end
  end

  # A refused non-Turbo form stays at its write URL (e.g. PUT /users). That is
  # still inside the account even when no GET route exists at that address.
  # Only GET routes may become a new return destination above.
  def account_referer?(path)
    %i[get post put patch delete].any? do |method|
      NavigationHelper.account_page?(controller_name_of(path, method: method))
    end
  end
end
