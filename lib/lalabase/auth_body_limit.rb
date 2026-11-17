# frozen_string_literal: true

require_relative 'body_limit'

module Lalabase
  # Refuses, at the sign-in door of clients (/api/auth/), a body nobody should
  # parse, before anything reads it. Why this is a middleware and where it sits:
  # Lalabase::BodyLimit.
  #
  # * Too large (413). The limit is the size the per-address brake reads
  #   (Rack::Attack LOGIN_BODY_LIMIT): an address that sits behind the part the
  #   brake reads would reach no bucket. A sign-in is two short fields and a
  #   device name. Content-Length is the caller's claim, so the start of the
  #   body is measured as well: a body sent in chunks carries no length.
  # * Bytes that are no UTF-8 (400). Rails refuses such a parameter itself, with
  #   a page of its own, and names its value in the error line of the log, at
  #   the level of production and past the parameter filter. Here that value
  #   may be a password.
  # * A body that is not sent as application/json is taken away, not refused:
  #   the door answers such a request itself (415, with its sentence), and no
  #   parser reads the body before it does. Rails' form parser names a value it
  #   cannot decode in the same error line ("invalid %-encoding"), and a
  #   password with a per cent sign from a client that forgot its content type
  #   is exactly such a value.
  #
  # In the public demo the door answers 404 to everything but the methods, and
  # so does this class: an instance without the door would not answer 413.
  class AuthBodyLimit < BodyLimit
    PATH_PREFIX = '/api/auth/'
    MAX_BODY_BYTES = 4.kilobytes

    def initialize(app)
      super(app, path_prefix: PATH_PREFIX, limit: MAX_BODY_BYTES)
    end

    JSON_MEDIA_TYPE = 'application/json'

    def call(env)
      return @app.call(env) unless under_prefix?(env)

      refusal = refusal_for(env)
      unless refusal
        take_body_away(env) unless Rack::MediaType.type(env['CONTENT_TYPE']) == JSON_MEDIA_TYPE
        return @app.call(env)
      end

      status, error = Lalabase::Demo.enabled? ? [404, 'not_found'] : refusal
      body = Api::V1::ErrorBody.build(error: error, code: (error == 'body_too_large' ? 'invalid_input' : nil)).to_json
      [status, { 'content-type' => 'application/json', 'content-length' => body.bytesize.to_s }, [body]]
    end

    private

    # @return [Array(Integer, String), nil] status and error of the refusal
    def refusal_for(env)
      return [413, 'body_too_large'] if env['CONTENT_LENGTH'].to_i > MAX_BODY_BYTES

      start = read_start(env)
      return [413, 'body_too_large'] if start.bytesize > MAX_BODY_BYTES

      [400, 'bad_request'] unless start.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    end

    # The header stays: the door reads it to say what it takes.
    def take_body_away(env)
      env['rack.input'] = StringIO.new(''.b)
      env['CONTENT_LENGTH'] = '0'
      env.delete('HTTP_TRANSFER_ENCODING')
    end

    # One byte more than the limit, so a longer body shows. Rewound: the
    # application reads the body from its start. An input that cannot be rewound
    # is left alone (the server of this application hands out none).
    def read_start(env)
      input = env['rack.input']
      return +'' unless input.respond_to?(:rewind)

      start = input.read(MAX_BODY_BYTES + 1).to_s
      input.rewind
      start
    end
  end
end
