# frozen_string_literal: true

class User < ApplicationRecord
  # === Which email the others see ===
  # THE single owner of the email a member shows to other people inside an
  # organisation: the people directory (list, lane, search, form), the members
  # page, the assistant, MCP and REST cards, pickers and name fallbacks. The
  # member chooses it in the display preferences:
  #
  #   login   - the address they sign in with (default; what everyone saw before)
  #   contact - a separate contact address (contact_email)
  #   none    - no email at all
  #
  # NOT for signing in, Devise, mails Lalabase sends, the member's own view of
  # their account (GET /api/v1/me) or the instance admin area: those keep
  # `email`. Lalabase never mails to contact_email.
  #
  # The check constraint users_email_visibility_known is the second line behind
  # the inclusion validation. Guard: spec/architecture/shown_email_guard_spec.rb.
  module EmailDisplay
    extend ActiveSupport::Concern

    EMAIL_VISIBILITIES = %w[login contact none].freeze
    MAX_CONTACT_EMAIL_LENGTH = 255

    included do
      normalizes :contact_email, with: ->(value) { value.to_s.strip.presence }

      validates :email_visibility, inclusion: { in: EMAIL_VISIBILITIES }
      validates :contact_email, presence: true, if: -> { email_visibility == 'contact' }
      validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP },
                                length: { maximum: MAX_CONTACT_EMAIL_LENGTH }, allow_nil: true

      # The users whose SHOWN email contains `fragment` (case-insensitive, LIKE
      # wildcards taken as text). A hidden login address never matches, so a
      # search cannot confirm that an address belongs to a member.
      scope :matching_shown_email, lambda { |fragment|
        pattern = "%#{sanitize_sql_like(fragment.to_s.downcase)}%"
        shows_login = where(email_visibility: 'login').where('LOWER(users.email) LIKE ?', pattern)
        shows_login.or(where(email_visibility: 'contact').where('LOWER(users.contact_email) LIKE ?', pattern))
      }
    end

    # The email others see, or nil when the member shows none. An unknown
    # value (impossible past the constraint) shows nothing rather than the
    # login address.
    def shown_email
      case email_visibility
      when 'login' then email
      when 'contact' then contact_email
      end
    end
  end
end
