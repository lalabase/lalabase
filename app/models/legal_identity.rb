# frozen_string_literal: true

# The operator of this instance and its external legal pages: the name in the footer of
# the login and sessionless pages, and the imprint, privacy and terms pages linked there,
# in the invitation consent, the AI opt-in and the data export.
#
# Stored as instance admin settings (SystemSetting, "Systemeinstellungen"), not in code
# and not in ENV: the core is open source, so a hard-coded operator would put the Lalabase
# cloud's company and terms on every self-hosted instance, and a setting survives every
# deploy. All four values are optional; blank means "powered by Lalabase" and no link.
class LegalIdentity
  include ActiveModel::Model

  PAGES = %i[imprint privacy terms].freeze
  # One address AND one text per page. The address wins: whoever has their own
  # website links it; whoever has none writes the text here and the
  # instance serves it itself. Without either there is no link.
  ATTRIBUTES = [:operator_name,
                *PAGES.map { |page| :"#{page}_page_url" },
                *PAGES.map { |page| :"#{page}_body" }].freeze
  URL_SCHEMES = %w[https http].freeze

  attr_reader(*ATTRIBUTES)

  validate :urls_are_absolute

  # One query per request: the footer asks for the name and three URLs on every page.
  def self.current
    Current.legal_identity ||= load
  end

  def self.load
    stored = SystemSetting.where(key: ATTRIBUTES.map { |attribute| setting_key(attribute) }).pluck(:key, :value).to_h
    new(ATTRIBUTES.index_with { |attribute| stored[setting_key(attribute)] })
  end

  def self.setting_key(attribute)
    "legal_#{attribute}"
  end

  def initialize(attributes = {})
    attributes = attributes.to_h.symbolize_keys
    ATTRIBUTES.each { |attribute| instance_variable_set(:"@#{attribute}", attributes[attribute].to_s.strip.presence) }
  end

  def url_for(page)
    raise ArgumentError, "unknown legal page #{page.inspect}" unless PAGES.include?(page.to_sym)

    public_send(:"#{page}_page_url")
  end

  # The text of the page as the operator wrote it, or nil. Rendered as Markdown
  # by whoever displays it; nothing here trusts it as HTML.
  def body_for(page)
    raise ArgumentError, "unknown legal page #{page.inspect}" unless PAGES.include?(page.to_sym)

    public_send(:"#{page}_body")
  end

  # Blank values are written too: clearing a field is how an admin removes a link. One
  # lookup for all four rows instead of SystemSetting.set per value, which would query the
  # same table four times in a row; the two attributes `set` assigns are repeated here.
  def save
    return false unless valid?

    SystemSetting.transaction do
      rows = SystemSetting.where(key: ATTRIBUTES.map { |attribute| self.class.setting_key(attribute) }).index_by(&:key)
      ATTRIBUTES.each do |attribute|
        key = self.class.setting_key(attribute)
        config = SystemSetting::SETTINGS.fetch(key.to_sym)
        row = rows[key] || SystemSetting.new(key: key)
        row.update!(data_type: config[:data_type], description: config[:description], value: public_send(attribute).to_s)
      end
    end
    Current.legal_identity = nil
    true
  end

  # Public and on the class, because it is the ONE answer in this app to "may this
  # stored address become a link": SystemSetting asks it for the console address in
  # the founder mail. A second copy of the scheme list would drift.
  def self.absolute_url?(url)
    uri = URI.parse(url.to_s)
    URL_SCHEMES.include?(uri.scheme&.downcase) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  private

  # An absolute http(s) URL or nothing. A relative path would break the link in the data
  # export, which a background job renders without a host, and a script URL runs on click.
  def urls_are_absolute
    PAGES.each do |page|
      attribute = :"#{page}_page_url"
      url = public_send(attribute)
      next if url.nil? || absolute_url?(url)

      errors.add(attribute, :not_absolute_url)
    end
  end

  def absolute_url?(url)
    self.class.absolute_url?(url)
  end
end
