# frozen_string_literal: true

# == Schema Information
#
# Table name: system_settings
#
#  id          :uuid             not null, primary key
#  data_type   :string           default("string")
#  description :text
#  key         :string           not null
#  value       :text
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_system_settings_on_key  (key) UNIQUE
#

class SystemSetting < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :data_type, inclusion: { in: %w[string boolean integer float json] }

  # Predefined settings
  # The one placeholder of founder_signup_console_url_template. Written out in
  # the admin form's hint as well, so it is a constant rather than a literal in
  # two places.
  # It is filled by substitution and is NOT a Ruby format string, see
  # .founder_signup_console_url for why.
  FOUNDER_SIGNUP_ACCOUNT_PLACEHOLDER = '%{account_id}' # rubocop:disable Style/FormatStringToken

  SETTINGS = {
    allow_registration: {
      default: true,
      data_type: 'boolean',
      description: 'Erlaubt oder verhindert neue Registrierungen'
    },
    registration_disabled_message: {
      default: I18n.t('models.system_setting.registration_disabled_message'),
      data_type: 'string',
      description: 'Nachricht, die angezeigt wird, wenn Registrierungen deaktiviert sind'
    },
    account_deletion_grace_period_days: {
      default: 30,
      data_type: 'integer',
      description: 'Wartezeit in Tagen bevor ein Account endgültig gelöscht wird (0-365)',
      min: 0,
      max: 365
    },
    # AI quota (S3): monthly included budget + goodwill buffer in ABSTRACT
    # credits (not cents). Start values 200/200 (= 100 % buffer) are derived from
    # the 2 € purchase cost cap and can be overridden per org in the admin backend.
    ai_quota_monthly_credits: {
      default: 200,
      data_type: 'integer',
      description: 'Monatliches KI-Inklusiv-Kontingent pro Organisation (Credits)',
      min: 0
    },
    ai_quota_grace_buffer_credits: {
      default: 200,
      data_type: 'integer',
      description: 'Kulanz-Puffer über dem Monatskontingent (Credits), bevor das harte Gate greift',
      min: 0
    },
    # Founder application (§ 12.3.4): who is notified when an application
    # comes in. Configurable instead of hardcoded, because the recipient changes before
    # the code does -- a stand-in, a second person, a separate collective address. Empty
    # deliberately means "no mail": the marker in the account list then carries the case
    # alone, instead of the mail going to a guessed address.
    founder_signup_notification_email: {
      default: nil,
      data_type: 'string',
      description: 'E-Mail-Adresse für die Benachrichtigung bei neuen Neugründer-Anträgen (leer = keine Mail)'
    },
    # Where the link in this mail points (doc/oss_core_split_plan.md 5.2). The
    # account page belongs to the operator console, and that runs in its own
    # internal process under an address that the core does not know and should not
    # know. But the core renders the mail. So a template with a placeholder is
    # stored here, and the core only fills in the ID. Empty means: the
    # mail carries no link.
    founder_signup_console_url_template: {
      default: nil,
      data_type: 'string',
      description: 'Adress-Vorlage der Betreiber-Konsole für den Link in der Neugründer-Mail, mit Platzhalter für die Konto-ID (leer = kein Link)'
    },
    # M0b/M0c (doc/abrechnungsmodell_plan.md §3): from when on the seat event stream
    # is complete. Set by the opening backfill, read by
    # SeatEvent.reconstructible_from. Empty means "not at all yet", and that is a
    # statement, not a gap: before that, no figure from the stream may reach an invoice.
    #
    # As a timestamp in ISO 8601 format in a string field, because the
    # settings know no datetime. Access goes through
    # .seat_stream_opened_at, not through get(), so the conversion sits in ONE
    # place.
    seat_stream_opened_at: {
      default: nil,
      data_type: 'string',
      description: 'Zeitpunkt, ab dem der Seat-Ereignisstrom vollständig ist (ISO 8601, leer = Eröffnung noch nicht gelaufen)'
    },
    # Operator identity (LegalIdentity): the name in the footer of the login and
    # sessionless pages and the external legal pages linked there, in the invitation
    # consent, the AI opt-in and the data export. Instance admin settings, not ENV, so
    # a self-hoster sets them without server access and a deploy cannot lose them.
    # Blank means "powered by Lalabase" and no link. Read and written through
    # LegalIdentity only, which checks that every URL is absolute.
    legal_operator_name: {
      default: nil,
      data_type: 'string',
      description: 'Name des Betreibers in der Fußzeile (leer = "powered by Lalabase")'
    },
    legal_imprint_page_url: {
      default: nil,
      data_type: 'string',
      description: 'Adresse des Impressums (absolut, leer = kein Link)'
    },
    legal_privacy_page_url: {
      default: nil,
      data_type: 'string',
      description: 'Adresse der Datenschutzerklärung (absolut, leer = kein Link)'
    },
    legal_terms_page_url: {
      default: nil,
      data_type: 'string',
      description: 'Adresse der AGB (absolut, leer = kein Link)'
    },
    # The text of the page, in case the operator does NOT host it elsewhere. A
    # stored address wins: whoever has their own website links it.
    # Markdown, rendered through the existing markdown helper (sanitised).
    legal_imprint_body: {
      default: nil,
      data_type: 'string',
      description: 'Impressum als Text (leer = keine Seite in dieser Instanz)'
    },
    legal_privacy_body: {
      default: nil,
      data_type: 'string',
      description: 'Datenschutzerklaerung als Text (leer = keine Seite in dieser Instanz)'
    },
    legal_terms_body: {
      default: nil,
      data_type: 'string',
      description: 'AGB als Text (leer = keine Seite in dieser Instanz)'
    },
    # Product knowledge (doc/product_knowledge_plan.md, D4): the newest change time (pages and
    # folders) of the help texts last synced into product_knowledge_entries. Written and read by
    # ProductKnowledge::EnsureFresh alone, so that a process still running an older release
    # never syncs the table back to its older files. 0 means "never synced".
    # No control in the admin area on purpose: there is nothing here for a person to set.
    product_knowledge_generation: {
      default: 0,
      data_type: 'integer',
      description: 'Dateistand der zuletzt abgeglichenen Hilfetexte (intern, 0 = noch nie abgeglichen)'
    }
  }.freeze

  # Getter for typed values
  def typed_value
    case data_type
    when 'boolean'
      ActiveModel::Type::Boolean.new.cast(value)
    when 'integer'
      value.to_i
    when 'float'
      value.to_f
    when 'json'
      begin
        JSON.parse(value)
      rescue StandardError
        {}
      end
    else
      value
    end
  end

  # Setter for typed values
  def typed_value=(val)
    self.value = case data_type
                 when 'boolean'
                   ActiveModel::Type::Boolean.new.cast(val).to_s
                 when 'json'
                   val.to_json
                 else
                   val.to_s
                 end
  end

  # Class methods for easy access
  class << self
    def get(key)
      setting = find_by(key: key.to_s)
      return setting.typed_value if setting

      # Fallback to default value
      default_config = SETTINGS[key.to_sym]
      return default_config[:default] if default_config

      nil
    end

    def set(key, value)
      setting = find_or_initialize_by(key: key.to_s)

      # Set data_type from configuration if present
      if SETTINGS[key.to_sym]
        setting.data_type = SETTINGS[key.to_sym][:data_type]
        setting.description = SETTINGS[key.to_sym][:description]
      end

      setting.typed_value = value
      setting.save!
      setting.typed_value
    end

    def allow_registration?
      get(:allow_registration) != false
    end

    def registration_disabled_message
      get(:registration_disabled_message) || I18n.t('models.system_setting.registration_disabled_message')
    end

    def account_deletion_grace_period_days
      value = get(:account_deletion_grace_period_days) || 30
      # Ensure the value is within the allowed range
      value = 0 if value < 0
      value = 365 if value > 365
      value
    end

    def set_account_deletion_grace_period_days(days)
      days = days.to_i
      days = 0 if days < 0
      days = 365 if days > 365
      set(:account_deletion_grace_period_days, days)
    end

    # AI quota defaults: clamped at 0 (a negative budget/buffer is
    # meaningless). QuotaLedger reads these when an org has no per-org override.
    def ai_quota_monthly_credits
      [get(:ai_quota_monthly_credits).to_i, 0].max
    end

    def ai_quota_grace_buffer_credits
      [get(:ai_quota_grace_buffer_credits).to_i, 0].max
    end

    def set_ai_quota_monthly_credits(credits)
      set(:ai_quota_monthly_credits, [credits.to_i, 0].max)
    end

    def set_ai_quota_grace_buffer_credits(credits)
      set(:ai_quota_grace_buffer_credits, [credits.to_i, 0].max)
    end

    # nil when unset or blank -- the caller skips the mail entirely rather than
    # delivering to "" and raising in the mailer.
    def founder_signup_notification_email
      get(:founder_signup_notification_email).presence
    end

    # Nothing, or an absolute http(s) address that carries the placeholder. A
    # relative path has no host inside a mail, a script URL runs on click, and
    # without the placeholder every mail would link the same page.
    def valid_founder_signup_console_url_template?(template)
      return true if template.blank?

      return false unless template.include?(FOUNDER_SIGNUP_ACCOUNT_PLACEHOLDER)

      # Checked with an id filled in: the braces of the placeholder are not valid in
      # a URI, so the template itself never parses. What is left after the
      # substitution is exactly what a mail will carry.
      LegalIdentity.absolute_url?(template.gsub(FOUNDER_SIGNUP_ACCOUNT_PLACEHOLDER, SecureRandom.uuid))
    end

    # nil while nothing is configured; the mail then carries no link.
    #
    # Substitution, NOT Kernel#format: format raises KeyError on a second, unknown
    # placeholder and ArgumentError on a stray percent sign, and it would do so in
    # a mailer job, for a value someone typed weeks earlier.
    def founder_signup_console_url(account)
      template = get(:founder_signup_console_url_template).presence
      return nil unless template

      template.gsub(FOUNDER_SIGNUP_ACCOUNT_PLACEHOLDER, account.id.to_s)
    end

    # nil while the opening backfill has never run. Callers must be able to say
    # "not reconstructible" rather than answer zero (§3).
    def seat_stream_opened_at
      raw = get(:seat_stream_opened_at).presence
      return nil if raw.nil?

      Time.zone.parse(raw)
    end

    # WRITE-ONCE. The stream became complete at one moment, and a later run
    # moving that moment forward would silently declare earlier, correctly
    # reconstructible periods unreadable. The backfill is idempotent for the same
    # reason.
    def seat_stream_opened_at!(moment)
      # One lookup, not read-then-set: `set` would query the same key again, and
      # two identical queries in a row are what an N+1 detector is for. The row
      # is written once in the life of an installation, so the duplication of
      # `set`'s two assignments is cheaper than the indirection.
      setting = find_or_initialize_by(key: 'seat_stream_opened_at')
      return Time.zone.parse(setting.value) if setting.value.present?

      config = SETTINGS[:seat_stream_opened_at]
      setting.data_type = config[:data_type]
      setting.description = config[:description]
      setting.typed_value = moment.utc.iso8601
      setting.save!
      moment
    end

    # Initialize default settings
    def initialize_defaults
      SETTINGS.each do |key, config|
        next if exists?(key: key.to_s)

        create!(
          key: key.to_s,
          value: config[:default].to_s,
          data_type: config[:data_type],
          description: config[:description]
        )
      end
    end
  end
end
