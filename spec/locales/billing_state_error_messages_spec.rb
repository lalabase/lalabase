# frozen_string_literal: true

require 'rails_helper'

# Guard: the validation errors of the billing-state fields are readable in both
# locales -- attribute NAME and message, not just the message.
#
# Why this exists (the drift it prevents), both halves observed on the way in:
#
# 1. `errors.full_messages` prefixes the humanised column name unless
#    `activerecord.attributes.account.*` supplies one. The German admin backend
#    rendered "Payment terms days muss kleiner oder gleich 30 sein" -- half
#    English, and only visible by looking at the page, since nothing raises.
#
# 2. `rails-i18n` is NOT in this app; every `errors.messages.*` key is hand
#    maintained. `not_a_number` and `not_an_integer` were simply absent, so a
#    non-numeric payment term rendered a raw "Translation missing. Options
#    considered were: ..." block INTO the operator page. `raise_on_missing_
#    translations` is off in every environment, so no spec would have noticed.
#
# Reads the loaded backend rather than `I18n.exists?`, for the same reason as
# spec/locales/billing_interval_keys_spec.rb: with the en->de fallback,
# `exists?` answers true for a key that exists only in German.
RSpec.describe 'Billing state error messages' do
  # The W3 fields (doc/billing_rechnungsstellung_r1_plan.md E2). Every one of
  # them can produce a validation error the operator has to read.
  billing_state_attributes = %i[billing_starts_on billing_interval payment_terms_days].freeze

  # The messages those validations actually reach for.
  error_messages = %i[invalid inclusion less_than_or_equal_to greater_than not_a_number not_an_integer].freeze

  locales = %i[de en].freeze

  def stored(locale, *path)
    I18n.backend.send(:translations)[locale]&.dig(*path)
  end

  before { I18n.backend.send(:init_translations) unless I18n.backend.initialized? }

  locales.each do |locale|
    billing_state_attributes.each do |attribute|
      it "names #{attribute} in #{locale}" do
        value = stored(locale, :activerecord, :attributes, :account, attribute)

        expect(value).to be_present,
                         "missing #{locale}.activerecord.attributes.account.#{attribute} — " \
                         'errors.full_messages would fall back to the humanised column name, ' \
                         'which reads as English inside a German sentence'
      end
    end

    error_messages.each do |message|
      it "has the #{message} message in #{locale}" do
        value = stored(locale, :errors, :messages, message)

        expect(value).to be_present,
                         "missing #{locale}.errors.messages.#{message} — rails-i18n is not " \
                         'installed here, so an absent key renders a raw "Translation missing" ' \
                         'block into the page instead of failing'
      end
    end
  end

  # The mechanism, not just the data: this is what the operator actually sees.
  it 'renders a fully German message for an over-long payment term' do
    account = Account.new(name: 'X', billing_interval: Subscriptions::Constants::INTERVAL_MONTHLY,
                          payment_terms_days: 60)

    I18n.with_locale(:de) do
      account.valid?

      expect(account.errors.full_messages.first).not_to include('Payment terms days')
      expect(account.errors.full_messages.first).to include('Zahlungsziel')
    end
  end

  it 'renders no "translation missing" for a non-numeric payment term' do
    account = Account.new(name: 'X', payment_terms_days: 'abc')

    I18n.with_locale(:de) do
      account.valid?

      expect(account.errors.full_messages.join).not_to match(/[Tt]ranslation missing/)
    end
  end
end
