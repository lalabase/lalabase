# frozen_string_literal: true

require 'lalabase/instance_settings'

# Separate logger for Pundit security warnings. On our servers it is a file
# that `rake pundit:warnings` reads. A container logs on stdout only
# (RAILS_LOG_TO_STDOUT=1, Lalabase::InstanceSettings): there the lines go to
# stdout, marked, and `docker compose logs web | grep pundit_security` finds them.
if Lalabase::InstanceSettings.log_to_file?
  PUNDIT_LOGGER = Logger.new(Rails.root.join('log', "pundit_security_#{Rails.env}.log"))
  PUNDIT_LOGGER.formatter = proc do |severity, datetime, _progname, msg|
    "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [#{severity}] #{msg}\n"
  end
else
  PUNDIT_LOGGER = Logger.new($stdout)
  PUNDIT_LOGGER.formatter = proc do |severity, datetime, _progname, msg|
    "#{datetime.strftime('%Y-%m-%d %H:%M:%S')} [pundit_security] [#{severity}] #{msg}\n"
  end
end

# Optional: Daily rotation of the log
# PUNDIT_LOGGER = Logger.new(Rails.root.join('log', "pundit_security_#{Rails.env}.log"), 'daily')

# Optional: Size-based rotation (e.g. max 100MB, keep 10 old files)
# PUNDIT_LOGGER = Logger.new(Rails.root.join('log', "pundit_security_#{Rails.env}.log"), 10, 100 * 1024 * 1024)
