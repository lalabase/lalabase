# frozen_string_literal: true

# Devise's controller test helper signs in by writing the session directly, without
# Warden's set_user event, so config/initializers/session_version.rb never stores the
# user's session_version and the first fetch would end the session. Real sign-ins (the
# form, the hand-off, Warden's login_as in request specs) all run the event; this mirrors
# it for controller specs only.
module DeviseSessionVersionForControllerSpecs
  def sign_in(resource, scope: nil)
    super
    scope ||= Devise::Mapping.find_scope!(resource)
    return unless resource.respond_to?(:session_version)

    warden.raw_session["warden.user.#{scope}.session"] ||= {}
    warden.raw_session["warden.user.#{scope}.session"][Lalabase::SessionVersion::KEY] = resource.session_version
  end
end

Devise::Test::ControllerHelpers.prepend(DeviseSessionVersionForControllerSpecs)
