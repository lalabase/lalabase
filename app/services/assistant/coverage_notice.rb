# frozen_string_literal: true

# Keeps the persisted scope caveat with both chat answers and saved analyses.

module Assistant
  class CoverageNotice
    def self.call(coverage:)
      return unless coverage.is_a?(Hash)

      key = 'views.organisations.chats.message'
      # A narrowing the user CHOSE is named, not counted: 1 of 12 reads as a
      # defect when it simply reflects a scope chip that is no longer alongside
      # a copied answer. The sentence must carry that choice with the result.
      notice = if coverage['chosen'].present?
                 I18n.t("#{key}.coverage_notice_chosen", project: coverage['chosen'])
               elsif coverage['searched'].is_a?(Integer) && coverage['total'].is_a?(Integer) && coverage['searched'] < coverage['total']
                 I18n.t("#{key}.coverage_notice", searched: coverage['searched'], total: coverage['total'])
               end
      # Outside is independent of the arithmetic: a tool may have read a source
      # outside the chosen project even when searched equals total (#642).
      # Alone it needs its own sentence; the appended wording borrows its subject
      # from the preceding notice and would be meaningless without it.
      return notice unless coverage['outside']
      return I18n.t("#{key}.coverage_notice_outside_only") unless notice

      "#{notice}. #{I18n.t("#{key}.coverage_notice_outside")}"
    end
  end
end
