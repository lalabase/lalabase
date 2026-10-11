# frozen_string_literal: true

# require 'sprockets/sass_compressor'
# class Sprockets::SassCompressor
#   TAILWIND_SEARCH = "--tw-".freeze
#   def call(*args)
#     input = if defined?(data)
#               data # sprockets 2.x
#             else
#               args[0][:data] #sprockets 3.x
#             end

#     return input if skip_compiling?(input) # added this line

#     SassC::Engine.new(
#       input,
#       {
#         style: :compressed
#       }
#     ).render
#   end

#   def skip_compiling?(body)
#     body.include?(TAILWIND_SEARCH)
#   end

# end
