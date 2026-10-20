# frozen_string_literal: true

# Base for all environments
threads_count = ENV.fetch('RAILS_MAX_THREADS', 1).to_i
threads threads_count, threads_count
plugin      :tmp_restart

# Set env dynamically
rails_env = ENV.fetch('RAILS_ENV', 'development')
environment rails_env

# Start the SolidQueue supervisor together with Puma
# Enabled via the ENV variable SOLID_QUEUE_IN_PUMA=1
# Note: phased restarts are not possible with this (the plugin needs preload)
plugin :solid_queue if ENV['SOLID_QUEUE_IN_PUMA']

# Environment-specific configuration.
#
# CAUTION: never put `port` at the top level of this file. Puma reads `port N`
# as `bind tcp://0.0.0.0:N` and ADDS that listener to every later `bind` instead
# of replacing it. A global `port` therefore handed staging and production a
# second, public listener on 0.0.0.0:3000 alongside their Unix socket: the whole
# application reachable over plain HTTP, past nginx, past TLS, and past any
# access control nginx enforces. Found 2026-08-14 — the Basic Auth that had just
# been put in front of stage.lalabase.com was bypassable by calling port 3000
# with an `X-Forwarded-Proto: https` header, and production answered 200 there
# for a request carrying `Host: lalabase.com`. Both nginx vhosts proxy to the
# Unix socket only, so the TCP listener served no one.
# Pinned by spec/config/puma_bind_guard_spec.rb.
#
# The operator console (doc/oss_core_split_plan.md 9.1) is a SECOND Puma on the
# same release, told apart by OPERATOR_CONSOLE in its systemd unit. It gets its
# own socket, pid and state file next to the public ones; nginx never proxies
# to it, an SSH tunnel does. The flag is read by Lalabase::OperatorConsole, the
# predicate the Rails settings use too, so socket and settings cannot disagree.
require File.expand_path('../lib/lalabase/operator_console', __dir__)
require File.expand_path('../lib/lalabase/demo', __dir__)

# The public demo (Lalabase::Demo) takes no body above its upload limit. Here, because
# Puma reads a whole body into a temporary file before the application sees it, so a
# limit further in would still let anybody fill the disk with one request.
http_content_length_limit Lalabase::Demo::MAX_UPLOAD_BYTES if Lalabase::Demo.enabled?

# Our servers run a Capistrano release, <deploy root>/releases/<timestamp>,
# reached through <deploy root>/current, with shared/ next to them. The root is
# read off where this file is, so the core names no server path. Puma is
# started as `puma -C config/puma.rb` in current/, and the working directory is
# the resolved release, so both shapes are handled. Outside such a directory a
# production process listens on its port like any other.
app_root = File.expand_path('..', __dir__)
deploy_root = if File.basename(File.dirname(app_root)) == 'releases'
                File.dirname(app_root, 2)
              elsif File.basename(app_root) == 'current'
                File.dirname(app_root)
              end
deploy_root = nil unless %w[staging production].include?(rails_env)
# The Docker image runs production in a container: no nginx, no deploy root,
# and the published port is the only way in. Its Dockerfile sets
# LALABASE_CONTAINER=1; only the exact value counts, the way OPERATOR_CONSOLE
# does. Puma reads this file before dotenv loads the shared .env, so a stray
# line there cannot put our servers on a TCP port.
container = ENV['LALABASE_CONTAINER'].to_s.strip == '1'

if container
  port ENV.fetch('PORT', 3000)
elsif deploy_root
  operator_console = Lalabase::OperatorConsole.enabled?
  suffix = operator_console ? '-operator' : ''
  # Puma creates a Unix socket with umask 0 (mode 0777) unless the bind says
  # otherwise. The public socket stays open for nginx; the console's is for the
  # deploy user alone, which the SSH tunnel and the deploy's health gate run as.
  socket_options = operator_console ? '?umask=0077' : ''
  bind "unix://#{deploy_root}/shared/tmp/sockets/puma#{suffix}.sock#{socket_options}"
  pidfile "#{deploy_root}/shared/tmp/pids/puma#{suffix}.pid"
  state_path "#{deploy_root}/shared/tmp/pids/puma#{suffix}.state"
  if operator_console
    # Single mode: one operator, one process. Cluster mode with one worker would
    # run a second full Rails, the master, for nothing.
    workers 0
  else
    workers 2
    preload_app!
  end
else
  # Local development and test: here the TCP listener is the point. `bin/dev`
  # exports PORT, and `bin/rails server -b 0.0.0.0` widens the host when the
  # Parallels VM needs to reach the app.
  port ENV.fetch('PORT', 3000)
end
