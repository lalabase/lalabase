# frozen_string_literal: true

require 'io/console'

# First run of a fresh installation: creates the first instance admin.
#
#   bin/rails lalabase:setup
#   LALABASE_ADMIN_EMAIL=... LALABASE_ADMIN_PASSWORD=... bin/rails lalabase:setup
#
# Without the variables it asks in the terminal; without a terminal (a container
# entrypoint) it stops instead of waiting for input nobody can give.
namespace :lalabase do
  desc 'Create the first instance admin (LALABASE_ADMIN_EMAIL, LALABASE_ADMIN_PASSWORD)'
  task setup: :environment do
    ask = lambda do |label, secret: false|
      abort "#{label} missing: set it in the environment or run this task in a terminal." unless $stdin.tty?

      print "#{label}: "
      answer = secret ? $stdin.noecho(&:gets) : $stdin.gets
      puts if secret
      answer.to_s.strip
    end

    email = ENV['LALABASE_ADMIN_EMAIL'].presence || ask.call('LALABASE_ADMIN_EMAIL')
    password = ENV['LALABASE_ADMIN_PASSWORD'].presence || ask.call('LALABASE_ADMIN_PASSWORD', secret: true)

    admin = Setup::CreateFirstAdmin.call(email: email, password: password)
    puts "Admin #{admin.email} created. Sign in at /admin, then register the first user at /users/sign_up."
  rescue Setup::CreateFirstAdmin::Refused => e
    abort "lalabase:setup: #{e.message}"
  end
end
