# frozen_string_literal: true

module Users
  # :lockable is on (config.maximum_attempts), so /users/unlock/new is a real
  # address a locked-out person reaches. Until 20.09.2026 no controller claimed
  # it: Devise's own ran with the default layout, which renders the signed-in
  # application chrome for a visitor who by definition cannot sign in.
  class UnlocksController < Devise::UnlocksController
    layout 'application_auth'

    # Same reason as Users::ConfirmationsController: load_tenant_from_session
    # sends a signed-in user without an organisation to /select_organisation,
    # and #show is opened from a mail wherever that mail is read.
    skip_before_action :load_tenant_from_session
  end
end
