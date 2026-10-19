# frozen_string_literal: true

# Demo mode (Lalabase::Demo). Both pieces are installed on every instance and ask
# the flag on each mail and each response, so an instance without LALABASE_DEMO
# delivers and answers as before.
#
# Explicit require: initializers run before the autoloader serves lib/ (same as
# operator_console.rb).
require 'lalabase/demo'

Rails.application.config.middleware.use Lalabase::Demo::NoIndex
ActiveSupport.on_load(:action_mailer) { register_interceptor(Lalabase::Demo::MailDrop) }
