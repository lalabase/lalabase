# frozen_string_literal: true

# Negative claims about what a response names: "the answer says nothing of the ticket the
# reader cannot open". One helper, so a ticket number is checked as a number everywhere.
#
#   expect_absent(response.body, 'Board decision on budget', 'Vorstand', hidden.id, 4711)
#
# A text is a substring, a Regexp a match, and a number (Integer or a string of digits) a
# number: not preceded or followed by a hex digit. A bare substring also matches inside a UUID
# or an asset digest, which turned the relation specs red by chance (CI of #950; the visibility
# spec of #949 had its own copy of this rule before).
#
# Like every negative claim, it proves something only next to a positive one in the same
# response (status and an expected row or text).
module ResponseAbsence
  def expect_absent(body, *needles)
    needles.each do |needle|
      case needle
      when Regexp then expect(body).not_to match(needle)
      when Integer, /\A\d+\z/ then expect(body).not_to match(/(?<!\h)#{needle}(?!\h)/)
      else expect(body).not_to include(needle)
      end
    end
  end
end

RSpec.configure do |config|
  config.include ResponseAbsence, type: :request
end
