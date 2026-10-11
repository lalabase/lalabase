# frozen_string_literal: true

require 'rails_helper'

# The helper behind every "names nothing of it" claim in a request spec
# (spec/support/response_absence.rb). A ticket number is a number: a bare substring also matches
# inside a UUID or an asset digest, which turned the relation specs red by chance (CI of #950).
RSpec.describe 'ResponseAbsence helper', type: :request do
  def fails?(body, *needles)
    expect_absent(body, *needles)
    false
  rescue RSpec::Expectations::ExpectationNotMetError
    true
  end

  it 'takes a number inside a UUID or a digest for no number' do
    body = 'data-ticket-id="5e2a4711-0c1d-4b7e" href="/assets/app-a94711f.css"'
    expect(fails?(body, 4711)).to be(false)
    expect(fails?(body, '4711')).to be(false)
  end

  it 'finds the number where a reader would see it' do
    ['#4711', 'Ticket 4711', '>4711<', '4711'].each do |body|
      expect(fails?(body, 4711)).to be(true), body
      expect(fails?(body, '4711')).to be(true), body
    end
  end

  it 'finds a text as a substring, and a pattern as a match' do
    expect(fails?('<p>Board decision on budget</p>', 'Board decision')).to be(true)
    expect(fails?('<p>Board</p>', /Bo+ard/)).to be(true)
    expect(fails?('<p>Other</p>', 'Board decision', /Bo+ard/, 4711)).to be(false)
  end
end
