# frozen_string_literal: true

# Tells the operator that someone asked for the new-founder discount
# (doc/billing_preisliste_rabatt_plan.md § 12.3.4).
#
# Why a mail at all, when the account list already carries a marker: the marker
# only works once somebody looks at the list. The promise made to the applicant
# is "we will call you", and without a push its response time would be "whenever
# I next open the admin area".
#
# Goes to the OPERATOR, never to the applicant -- nothing here is customer copy.
class FounderSignupMailer < ApplicationMailer
  # The operator's language, not the applicant's. Without this the mail renders
  # in whatever locale the sign-up request happened to run under -- an English
  # visitor would send the operator an English work item.
  OPERATOR_LOCALE = :de

  def new_request(founder_signup)
    @founder_signup = founder_signup
    @account = founder_signup.account
    # nil unless the operator stored an address. The account page belongs to the
    # operator console, whose routes do not exist in the process that renders this
    # mail, so the template must never call a route helper for it
    # (spec/architecture/admin_operator_boundary_guard_spec.rb).
    @console_url = SystemSetting.founder_signup_console_url(@account)

    recipient = SystemSetting.founder_signup_notification_email
    # No configured address is a valid state (§ 12.3.4): the marker in the
    # account list carries the case alone. Delivering to a guessed address
    # would be worse than not delivering.
    return if recipient.blank?

    I18n.with_locale(OPERATOR_LOCALE) do
      mail(
        to: recipient,
        subject: t('founder_signup_mailer.new_request.subject', company: @founder_signup.company_name)
      )
    end
  end
end
