# frozen_string_literal: true

# Content Security Policy (CSP) header configuration
# Protects against XSS and other injection attacks.
#
# IMPORTANT: Starts in report-only mode. After validation in production
# `content_security_policy_report_only` can be set to false.

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    # Since 06/2026 all frontend dependencies are vendored (vendor/javascript +
    # vendor/assets) — no more CDN hosts needed. New CDN requests show up
    # as a CSP violation in the report.
    policy.font_src    :self, :data
    policy.img_src     :self, :data, :https
    policy.object_src  :none
    policy.script_src  :self, :unsafe_inline
    policy.style_src   :self, :unsafe_inline
    policy.connect_src :self, :wss # WebSocket for ActionCable
    policy.frame_ancestors :self
    policy.base_uri    :self
    policy.form_action :self
  end

  # Report-only mode: CSP violations are logged but not blocked.
  # Set to false after successful validation in production.
  config.content_security_policy_report_only = true
end
