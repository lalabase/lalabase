# frozen_string_literal: true

# The account's profile tab has two forms: name and login address (Devise, behind the
# current password) and what the others see (picture, shown email; no password). The
# second one's anchor has one owner here: the tab writes it as the section's id, and a
# link or a redirect to it asks for the same word.
module AccountProfileHelper
  DISPLAY_ANCHOR = 'section-display'

  def account_display_path
    edit_user_registration_path(anchor: DISPLAY_ANCHOR)
  end
end
