# frozen_string_literal: true

# Where a new customer came from, captured ONCE on the first page of the first
# visit and frozen onto the account at registration (doc/akquise_herkunft.md).
#
# This is the value object, and it is the single owner of three rules that would
# otherwise get re-implemented at every call site: which parameters are read,
# how they are trimmed, and how the many raw fields collapse into the ONE label
# an evaluation groups by (#channel).
#
# Deliberately narrow on privacy grounds: the referrer is reduced to its HOST,
# never the full URL, because the path of a foreign page can carry a search term
# or a person. No IP and no user agent -- those already live on UserActivity for
# signed-in traffic, and duplicating them into a permanent column on the billing
# entity would widen the retention promise for no analytical gain.
class AcquisitionSource
  # Every key that may end up in the jsonb column. Anything not listed here is
  # dropped, so a crafted URL cannot inflate the record with arbitrary content.
  REF = 'ref'
  UTM_SOURCE = 'utm_source'
  UTM_MEDIUM = 'utm_medium'
  UTM_CAMPAIGN = 'utm_campaign'
  REFERRER_HOST = 'referrer_host'
  LANDING_PATH = 'landing_path'
  FIRST_SEEN_AT = 'first_seen_at'

  KEYS = [REF, UTM_SOURCE, UTM_MEDIUM, UTM_CAMPAIGN, REFERRER_HOST, LANDING_PATH, FIRST_SEEN_AT].freeze

  # The keys read straight from the query string, in the order they are offered
  # to #channel below.
  PARAM_KEYS = [REF, UTM_SOURCE, UTM_MEDIUM, UTM_CAMPAIGN].freeze

  # A value long enough for real campaign names and short enough that a hostile
  # query string cannot turn a row into a payload.
  MAX_VALUE_LENGTH = 200

  # How long an origin stays on the account (privacy policy § 4.2). The question
  # "where did this customer come from" has no answer left worth keeping after a
  # year, so the promise is a deletion deadline rather than "for as long as the
  # account exists". Enforced by AcquisitionPurgeJob -- a retention sentence
  # without a sweeper is prose, not a mechanism.
  RETENTION = 12.months

  # The label for traffic that declared nothing and arrived without a referrer.
  # A constant rather than a literal because the admin view, the report and the
  # specs all have to agree on it.
  CHANNEL_DIRECT = 'direct'

  attr_reader :to_h

  def initialize(attributes)
    @to_h = attributes.freeze
  end

  # Builds a source from an incoming request.
  #
  # A visit that declares NOTHING still produces a record, and that is the
  # point: "arrived directly on /features" is one of the two questions this
  # whole column exists to answer. Dropping those rows would leave an
  # evaluation that only ever sees campaign traffic and reads as if nobody
  # comes any other way.
  def self.from_request(request)
    attributes = PARAM_KEYS.index_with { |key| clean(request.query_parameters[key]) }
    attributes[REFERRER_HOST] = referrer_host_of(request)
    attributes[LANDING_PATH] = clean(request.path)
    attributes = attributes.compact

    return nil if attributes.empty?

    attributes[FIRST_SEEN_AT] = Time.current.utc.iso8601
    new(attributes)
  end

  # Rebuilds a source from what was stored, tolerating both a stored hash and
  # nil so callers do not each repeat the guard.
  def self.from_stored(value)
    return nil if value.blank?

    attributes = value.to_h.slice(*KEYS).compact
    attributes.presence && new(attributes)
  end

  # The ONE label an evaluation groups by. The order is the order of intent: a
  # ref we handed out ourselves beats a campaign parameter, which beats the
  # host a browser happened to report, which beats knowing nothing.
  def channel
    to_h[REF].presence ||
      to_h[UTM_SOURCE].presence ||
      to_h[REFERRER_HOST].presence ||
      CHANNEL_DIRECT
  end

  def landing_path
    to_h[LANDING_PATH]
  end

  def first_seen_at
    value = to_h[FIRST_SEEN_AT]
    return nil if value.blank?

    Time.zone.parse(value)
  rescue ArgumentError
    # A stored timestamp that no longer parses must not take an admin page down;
    # the row still carries a usable channel.
    nil
  end

  # Only the HOST of the referrer, and only for a FOREIGN host: an internal
  # referrer means the visitor was already here, which says nothing about where
  # they came from.
  def self.referrer_host_of(request)
    referrer = request.referer.presence
    return nil if referrer.blank?

    host = begin
      URI.parse(referrer).host
    rescue URI::InvalidURIError
      nil
    end
    return nil if host.blank? || host.casecmp?(request.host)

    clean(host)
  end

  def self.clean(value)
    return nil if value.blank?

    value.to_s.strip.truncate(MAX_VALUE_LENGTH).presence
  end

  private_class_method :referrer_host_of, :clean
end
