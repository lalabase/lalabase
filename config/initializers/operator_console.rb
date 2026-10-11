# frozen_string_literal: true

# The operator console process (doc/oss_core_split_plan.md 9.1) differs from the
# public process in a few settings: localhost as host, no TLS, no asset host, own
# session cookie. Lalabase::OperatorConsole holds them; this file only asks
# whether this process is the console. The console's systemd unit sets the
# flag. In every other process this does nothing.
#
# The flag alone does not decide it: a stray OPERATOR_CONSOLE in the shared .env
# would reach the public process as well. Without the engine the process
# refuses to boot instead (Lalabase::OperatorConsole.require_engine!).
#
# Explicit require: initializers run before the autoloader serves lib/ (same
# as provisioning_configuration.rb and Lalabase::ProvisioningBodyLimit).
require 'lalabase/operator_console'

if Lalabase::OperatorConsole.enabled?
  Lalabase::OperatorConsole.require_engine!
  Lalabase::OperatorConsole.apply!(Rails.application.config, env: Rails.env)
end
