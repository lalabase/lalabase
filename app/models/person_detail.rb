# frozen_string_literal: true

# One additional detail of a person (people.additional_details, a JSONB array
# of at most MAX entries): a kind, a free label and a value, say
# { "kind" => "phone", "label" => "Fax", "value" => "+49 30 1234568" }.
#
# Not an ActiveRecord model: the one owner of the rule. Kinds, limits,
# normalisation and validation live here and nowhere else; Person validates
# through it, Actors::SavePerson normalizes the form through it, and the form
# (kinds, input types, MAX), the lane (links, dates), the search and the
# export ask it. The check constraint people_additional_details_shape repeats
# only "an array of at most 10".
#
# The kind decides the behaviour (a tel: or mailto: link, a date in the
# reader's language); the label only says what the value means. A fax is a
# phone labelled "Fax". No reminders for dates, and the search reads the
# values, never the labels ("Fax" would find everybody with a fax).
class PersonDetail
  KINDS = %w[phone email url date address text].freeze
  KEYS = %w[kind label value].freeze
  MAX = 10
  MAX_LABEL_LENGTH = 60
  MAX_VALUE_LENGTH = 255
  MAX_ADDRESS_LENGTH = 500
  URL_SCHEMES = %w[http https].freeze
  # The input of the form per kind; "textarea" is the multi-line address.
  INPUT_TYPES = { 'phone' => 'tel', 'email' => 'email', 'url' => 'url', 'date' => 'date',
                  'address' => 'textarea', 'text' => 'text' }.freeze
  # The form always sends this key next to the indexed rows
  # (person[additional_details][sent]), so removing the last detail clears the
  # list. A request without additional_details at all leaves the list alone.
  FORM_MARKER = 'sent'
  # The indexes of the form's rows; anything else in the hash is ignored.
  INDEX_KEY = /\A\d{1,9}\z/
  ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/
  LINE_BREAK = /\r\n|\r|\n/
  NON_ASCII = /[^\x00-\x7F]/
  INVISIBLE = /[\p{Cc}\p{Cf}]/

  attr_reader :kind, :label, :value

  # Raw input in, a list of clean entries out: an array of hashes, or the
  # indexed hash of the form ({"0" => {...}, "3" => {...}}, ordered by index).
  # Only the three keys, as strings; label and value squeezed (an address keeps
  # its lines); a row without label and value is dropped (an empty row of the
  # form). A row with a label but no value stays, so the validation names it
  # instead of losing it behind a success (a value the browser emptied). An unknown kind is kept for
  # the validation. Junk from a hand-made request is skipped, never raised on.
  def self.normalize(raw)
    rows(raw).filter_map { |row| clean(row) }
  end

  # What is wrong with a list, as [problem, options] pairs; empty when valid.
  # The position (1-based) goes into the options of each entry's problem, for
  # the messages under activerecord.errors.models.person.attributes.
  def self.problems(list)
    return [[:not_a_list, {}]] unless list.is_a?(Array)
    return [[:too_many, { count: MAX }]] if list.size > MAX

    list.each_with_index.flat_map do |entry, index|
      new(entry).problems.map { |problem, options| [problem, { position: index + 1 }.merge(options)] }
    end
  end

  # The values the directory search reads (People::Directory), never a label.
  def self.search_values(list)
    return [] unless list.is_a?(Array)

    list.map { |entry| new(entry).value }.compact_blank
  end

  def self.max_value_length(kind)
    kind == 'address' ? MAX_ADDRESS_LENGTH : MAX_VALUE_LENGTH
  end

  def self.rows(raw)
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    case raw
    when Array then raw
    when Hash
      raw.select { |key, _row| INDEX_KEY.match?(key.to_s) }.sort_by { |key, _row| key.to_s.to_i }.map(&:last)
    else []
    end
  end
  private_class_method :rows

  def self.clean(row)
    row = row.to_unsafe_h if row.respond_to?(:to_unsafe_h)
    return unless row.is_a?(Hash)

    kind = string_in(row, 'kind')&.squish
    value = string_in(row, 'value').to_s
    value = kind == 'address' ? address_lines(value).join("\n") : value.squish
    label = string_in(row, 'label').to_s.squish
    return if value.empty? && label.empty?

    { 'kind' => kind, 'label' => label, 'value' => value }
  end
  private_class_method :clean

  # A string read from a row (string or symbol key), nil for anything else.
  def self.string_in(row, key)
    found = row.key?(key) ? row[key] : row[key.to_sym]
    case found
    when String then found
    when Symbol, Numeric then found.to_s
    end
  end

  def self.address_lines(value)
    value.split(LINE_BREAK).map(&:squish).compact_blank
  end

  # A stored entry, read without trusting it: written around the validation
  # (a console, update_column) it still renders, and nothing here raises.
  # The form cannot show such an entry faithfully (an unknown kind falls back
  # to the first option, a malformed date to an empty date field), so the next
  # save through the form may refuse or drop it. Only writes around the
  # validation can store one.
  def initialize(entry)
    entry = {} unless entry.is_a?(Hash)
    @kind = self.class.string_in(entry, 'kind')
    @label = self.class.string_in(entry, 'label').to_s
    @value = self.class.string_in(entry, 'value').to_s
  end

  def known_kind?
    KINDS.include?(kind)
  end

  def problems
    found = []
    found << [:unknown_kind, {}] unless known_kind?
    return found << [:value_missing, {}] if value.blank?

    found << [:label_too_long, { count: MAX_LABEL_LENGTH }] if label.length > MAX_LABEL_LENGTH
    max = self.class.max_value_length(kind)
    found << [:value_too_long, { count: max }] if value.length > max
    found << [:"invalid_#{kind}", {}] if known_kind? && !well_formed?
    found
  end

  # Where a click on the value goes, or nil: tel: through the digits, mailto:,
  # an http(s) url as written. Only for a well-formed value, so a url stored
  # around the validation (javascript:, data:) is never a link.
  def href
    return unless well_formed?

    case kind
    when 'phone' then "tel:#{value.gsub(/[^\d+]/, '')}"
    when 'email' then "mailto:#{value}"
    when 'url' then value
    end
  end

  # The date of a date detail, or nil. The rule of a browser's date field:
  # Gregorian, from year 1 (Ruby alone takes year 0 and Julian leap days
  # before 1582, which the field would show empty and the next save lose).
  def date
    return unless kind == 'date' && ISO_DATE.match?(value)

    parsed = Date.iso8601(value, Date::GREGORIAN)
    parsed if parsed.year.positive?
  rescue Date::Error
    nil
  end

  def lines
    self.class.address_lines(value)
  end

  private

  def well_formed?
    case kind
    when 'phone' then value.match?(/\d/)
    when 'email' then value.match?(URI::MailTo::EMAIL_REGEXP)
    when 'date' then !date.nil?
    when 'url' then http_url?
    else known_kind?
    end
  end

  # A web address may carry umlauts ("https://example.com/wiki/Köln", an
  # umlaut domain), which a browser accepts and URI.parse does not: they are
  # escaped for the check only, the stored value stays as written. Control and
  # format characters (bidi overrides, zero-width, soft hyphen) are refused
  # first: they would change what the link shows, or break its host.
  def http_url?
    return false if value.match?(INVISIBLE)

    uri = URI.parse(value.gsub(NON_ASCII) { |char| CGI.escape(char) })
    URL_SCHEMES.include?(uri.scheme.to_s.downcase) && uri.host.present?
  rescue URI::Error
    false
  end
end
