# frozen_string_literal: true

# What a visitor of the public demo (Lalabase::Demo) cannot do. Everybody signs in
# to the same account, so whatever is stored on the person is stored for every
# visitor at once, and whatever leaves the instance leaves with its name on it.
#
# A closed list of controller actions, inactive unless demo mode is on. Each
# entry says why. spec/architecture/demo_restrictions_guard_spec.rb holds that
# every entry names a routed action of a controller that runs this check; a new
# entry is a decision, not a convenience.
#
# Not here, because a policy already says no to the demo person (team role, no
# account admin): organisation settings, roles, AI settings and packages,
# billing. Mail needs no entry either: Lalabase::Demo::MailDrop drops all of it.
module DemoRestrictions
  extend ActiveSupport::Concern

  ALL = :all

  BLOCKED = {
    # Sign-up (no accounts outside the demo), email and password change (one
    # visitor would lock out the rest), deleting the account. `edit` shows the
    # page; nothing on it can be saved.
    'users/registrations' => %w[new create update destroy cancel],
    # The reset link goes out by mail; the page would promise one that never comes.
    'users/passwords' => ALL,
    'account_deletions' => ALL,
    'cancel_account_deletions' => ALL,
    # Scripted access (API, MCP) to an account that belongs to everybody.
    'users/personal_access_tokens' => ALL,
    # Language, session timeout, date format: stored on the shared person.
    'user_preferences' => %w[update],
    'user_data_exports' => ALL,
    # The demo stays one world.
    'organisations' => %w[new create],
    'organisations/invitations' => ALL,
    # Each of these makes the instance fetch from an address a visitor types.
    'organisations/project_repositories' => %w[new create update_token reindex],
    'organisations/documentation_sets' => %w[new create edit update sync],
    'organisations/codebase_import_files' => ALL
  }.freeze

  included do
    before_action :refuse_in_demo, if: -> { Lalabase::Demo.enabled? }
  end

  def self.blocked?(controller_path, action)
    actions = BLOCKED[controller_path]
    actions == ALL || Array(actions).include?(action.to_s)
  end

  private

  def refuse_in_demo
    return unless DemoRestrictions.blocked?(controller_path, action_name)

    message = t('views.demo.blocked')
    return render(json: { error: message }, status: :forbidden) if request.format.json?

    redirect_back_or_to(user_signed_in? ? user_home_path(current_user) : new_user_session_path,
                        alert: message, status: :see_other)
  end
end
