# frozen_string_literal: true

# Log out everywhere (doc/org_subdomains_plan.md, S3). Every host keeps a session of its own
# (host-only cookie), and a cookie session cannot be revoked one by one. So a session carries
# the user's session_version from its sign-in, every request compares it, and signing out
# (Users::SessionsController#destroy) raises the number: the session on every other host
# no longer matches and ends with its next request. A session without the number (one from
# before this rule) ends the same way.
#
# Only users have the number; backend accounts sign in elsewhere (Admin::Authentication).
module Lalabase
  module SessionVersion
    KEY = 'session_version'
  end
end

Warden::Manager.after_set_user except: :fetch do |user, warden, options|
  next unless options[:scope] == :user && user.respond_to?(:session_version)

  warden.session(:user)[Lalabase::SessionVersion::KEY] = user.session_version
end

Warden::Manager.after_set_user only: :fetch do |user, warden, options|
  next unless options[:scope] == :user && user.respond_to?(:session_version)
  next if warden.session(:user)[Lalabase::SessionVersion::KEY] == user.session_version

  warden.logout(:user)
  throw :warden, scope: :user, message: :unauthenticated
end
