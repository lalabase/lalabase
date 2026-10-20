# frozen_string_literal: true

# The public demo (Lalabase::Demo). Both tasks need LALABASE_DEMO=1.
#
#   bin/rails lalabase:demo:setup   once, on a fresh instance: marker, registration
#                                   closed, first world
#   bin/rails lalabase:demo:reset   the nightly reset, by hand
namespace :lalabase do
  namespace :demo do
    desc 'Turn a fresh instance into the public demo (needs LALABASE_DEMO=1, no organisations)'
    task setup: :environment do
      world = Lalabase::Demo::Setup.call
      puts "Demo ready. Sign in as #{world.signed_in.email}; it resets every night at " \
           "#{Lalabase::Demo.reset_time} UTC."
    rescue Lalabase::Demo::Setup::Refused => e
      abort "lalabase:demo:setup: #{e.message}"
    end

    desc 'Reset the public demo now (needs LALABASE_DEMO=1 and lalabase:demo:setup)'
    task reset: :environment do
      Lalabase::Demo::Reset.call
      puts 'Demo reset.'
    rescue Lalabase::Demo::Reset::Refused => e
      abort "lalabase:demo:reset: #{e.message}"
    end
  end
end
