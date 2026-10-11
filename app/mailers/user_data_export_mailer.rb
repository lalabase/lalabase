# frozen_string_literal: true

# "Your data export is ready" notification. The mail links to the export PAGE
# (login + fresh signed URL required), NEVER to the archive itself — mailbox
# possession must not grant access to the full PII bundle.
class UserDataExportMailer < ApplicationMailer
  def ready
    @export = params[:user_data_export]
    @user = @export.user

    I18n.with_locale(@user.language_preference.presence || I18n.default_locale) do
      mail(to: @user.email, subject: I18n.t('user_data_export_mailer.ready.subject'))
    end
  end
end
