# frozen_string_literal: true

# Demo mode (Lalabase::Demo). All three pieces are installed on every instance and ask
# the flag on each mail, request and response, so an instance without LALABASE_DEMO
# delivers and answers as before.
#
# Explicit require: initializers run before the autoloader serves lib/ (same as
# operator_console.rb).
require 'lalabase/demo'

Rails.application.config.middleware.use Lalabase::Demo::NoIndex
# First in the stack: Rack::MethodOverride parses a form body long before any
# controller could refuse it.
Rails.application.config.middleware.insert_before 0, Lalabase::Demo::UploadLimit
ActiveSupport.on_load(:action_mailer) { register_interceptor(Lalabase::Demo::MailDrop) }
