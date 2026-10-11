# frozen_string_literal: true

require 'rails_helper'

# ONE home for the three words a billing state can be called.
#
# Before S1 (01.09.2026) the same three states were named in NINE places, with
# five different German words for the same idea: Berechnet / Abgerechnet,
# Zur Abrechnung / In Abrechnung, Ohne Rechnung / Nicht berechnet / Offen. Every
# copy was legal (the duplicate-key guard next door only sees collisions inside
# ONE scope), every copy was a page that said something different about the same
# row, and one of them was not even i18n but a hardcoded Ruby string.
#
# So this file pins both halves: the owner is complete in BOTH languages, and no
# retired home has come back. Missing English would be invisible without it —
# config/initializers/i18n.rb sets fallbacks = [:de], so an English page would
# quietly render German. `fallback: false` is what makes I18n.exists? and
# I18n.t answer the question that was asked.
#
# The other half of S1 (every renderer goes through one helper and iterates one
# constant) is pinned by spec/architecture/billing_state_vocabulary_guard_spec.rb.
RSpec.describe 'time list billing words locale parity' do
  # Locals, not constants: RuboCop refuses constants defined inside a block, and
  # the guard next door (chat_persona_view_keys_spec) does the same.
  scope = 'views.time_sessions.billing_status'

  # The three states, from the constant rather than a literal list: a bucket
  # added to TimeSession::BILLING_STATUS_FILTERS without a word fails here.
  # :mixed and :no_sessions are subject-level answers a single session cannot
  # give; :no_sessions deliberately has no word (a subject with nothing booked
  # shows nothing).
  states = TimeSession::BILLING_STATUS_FILTERS + %w[mixed]
  # The sentences the table builds around them.
  phrases = %w[partial hidden_note visible_sum without_subject]

  %i[de en].each do |locale|
    states.each do |state|
      it "defines #{scope}.#{state} in #{locale}" do
        word = I18n.t("#{scope}.#{state}", locale: locale, fallback: false)

        expect(word).to be_present
        expect(word.downcase).not_to include('translation missing')
      end
    end

    phrases.each do |phrase|
      it "defines #{scope}.#{phrase} in #{locale}" do
        text = I18n.t("#{scope}.#{phrase}", locale: locale, fallback: false,
                                            percent: 50, shown: '01:00', total: '02:00', hidden: '01:00')

        expect(text).to be_present
        expect(text.downcase).not_to include('translation missing')
      end
    end

    %w[entries_count].each do |counted|
      it "defines both plural forms of #{scope}.#{counted} in #{locale}" do
        [1, 2].each do |count|
          text = I18n.t("#{scope}.#{counted}", locale: locale, count: count, fallback: false)

          expect(text).to be_present
          expect(text).to include(count.to_s)
        end
      end
    end
  end

  # The share is a number the WORD does not carry, so the sentence has to leave a
  # place for it. Without the interpolation the row would say "teilweise  %".
  it 'keeps the percent placeholder in both languages' do
    %i[de en].each do |locale|
      expect(I18n.t("#{scope}.partial", locale: locale, percent: 61, fallback: false)).to include('61')
    end
  end

  # D1: Rechnung and Abrechnung are two things. An invoice number is a Rechnung;
  # the bundle of hours it is built from is an Abrechnung. Since the words were
  # unified, none of the three may say "Rechnung" — that was the whole reason
  # "Ohne Rechnung" and "Nicht berechnet" had to go.
  it 'keeps "Rechnung" out of the three German words' do
    TimeSession::BILLING_STATUS_FILTERS.each do |state|
      expect(I18n.t("#{scope}.#{state}", locale: :de, fallback: false)).not_to match(/\brechnung\b/i)
    end
  end

  # Every home the words were evicted from, by exact key. A re-introduction is
  # not an error anywhere else: the key would simply exist, the page would
  # render, and the two words would drift apart again in silence.
  #
  # Only ever grows. A new surface that needs the words reads the owner.
  retired = [
    # the fold's own name for the loose bucket, before it was called by its bucket name
    'views.time_sessions.billing_status.open',
    # the time list's status pills
    'views.organisations.time_sessions.index.filter_status_billed',
    'views.organisations.time_sessions.index.filter_status_in_billing',
    'views.organisations.time_sessions.index.filter_status_without_billing',
    'views.organisations.time_sessions.index.filter_status_unbilled',
    # the share bar's short copy, and the dead trio of an older row layout
    'views.organisations.time_sessions.index_table.status_short_billed',
    'views.organisations.time_sessions.index_table.status_short_grouped',
    'views.organisations.time_sessions.index_table.status_short_open',
    'views.organisations.time_sessions.index_table.status_billed',
    'views.organisations.time_sessions.index_table.status_open',
    'views.organisations.time_sessions.index_table.status_grouped',
    # the overview table's column headers
    'views.organisations.time_sessions.billing_overview_panel.col_billed',
    'views.organisations.time_sessions.billing_overview_panel.col_in_billing',
    'views.organisations.time_sessions.billing_overview_panel.col_without_billing',
    # the billings list, which called the same two states Offen and Berechnet
    'views.organisations.time_session_groups.index.filter_status_unbilled',
    'views.organisations.time_session_groups.index.filter_status_billed',
    # the assistant report's totals
    'views.organisations.assistant_artefacts.report.buckets.billed',
    'views.organisations.assistant_artefacts.report.buckets.in_billing',
    'views.organisations.assistant_artefacts.report.buckets.without_billing',
    # the billing-pipeline widget on the overview
    'overview.billing.without_billing',
    'overview.billing.in_billing',
    'overview.billing.billed',
    # the projects-table widget's two hour columns
    'dashboard.briefing.sections.projects.table.in_billing',
    'dashboard.briefing.sections.projects.table.without_billing',
    # the chip carried them alone before it joined the list
    'components.subject_time_summary.billing',
    'components.subject_time_summary.billing_short'
  ]

  retired.each do |key|
    it "has no second home at #{key}" do
      %i[de en].each do |locale|
        expect(I18n.exists?(key, locale, fallback: false)).to be(false)
      end
    end
  end

  # The badge on a single booking used to build its tooltips by string
  # interpolation in Ruby, which meant an English reader got German. Both are
  # real keys now, and both carry their placeholder.
  it 'defines the billing badge tooltips in both languages, with their placeholders' do
    %i[de en].each do |locale|
      billed = I18n.t('components.time_session_billing_status.tooltip_billed',
                      locale: locale, fallback: false, invoice: 'INV-7', date: '1. Juli 2026')
      in_billing = I18n.t('components.time_session_billing_status.tooltip_in_billing',
                          locale: locale, fallback: false, name: 'August')

      expect(billed).to include('INV-7').and include('1. Juli 2026')
      expect(in_billing).to include('August')
    end
  end
end
