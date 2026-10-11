# frozen_string_literal: true

# Remembers where an anonymous visitor came from, so the registration further
# down the funnel can freeze it onto the account (doc/akquise_herkunft.md).
#
# The store is the EXISTING Rails session. That is the whole reason this is a
# handful of lines instead of an analytics stack: the session cookie is
# technically necessary and already set, so nothing here adds a cookie, and
# with it no consent banner under § 25 TDDG.
#
# Written exactly ONCE per session, on the first page seen. Later pages must not
# overwrite it -- the question is where someone entered, and a visitor who lands
# via a campaign link and then clicks to the pricing page would otherwise be
# recorded as having arrived at the pricing page from nowhere.
module AcquisitionTracking
  extend ActiveSupport::Concern

  SESSION_KEY = :acquisition

  included do
    before_action :remember_acquisition_source, unless: :user_signed_in?
  end

  private

  def remember_acquisition_source
    return if session[SESSION_KEY].present?
    # Only real page views: an asset, a Turbo Stream or a POST is not an entry
    # point, and recording one would attribute the visit to whatever internal
    # path happened to answer first.
    return unless request.get? && request.format.html?

    source = AcquisitionSource.from_request(request)
    return if source.nil?

    session[SESSION_KEY] = source.to_h
  end

  # The raw stored hash, handed to Actors::CreateSignup at registration, which
  # cleans it with AcquisitionSource.from_stored. Only read here: a signup the
  # form rejects must keep the origin for the next attempt.
  def stored_acquisition_source
    session[SESSION_KEY]
  end

  # Called once the signup succeeded: the source belongs to the account now, and
  # leaving it behind would attach the same origin to a second account created
  # from the same browser.
  def forget_acquisition_source
    session.delete(SESSION_KEY)
  end
end
