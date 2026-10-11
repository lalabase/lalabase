# frozen_string_literal: true

# What: The three states of an organisation's AI connection (L10 of
#   doc/ki_bereich_navigation_plan.md).
# Type: Model spec — a closed set of outcomes plus its deliberate NULL.
# Why (philosophy): The plan's hub card carries "Verbindung fehlerhaft" as a state it
#   could not reach, because nothing persisted the result of a connection test — it
#   lived only as a flash message. Three states have to stay apart: never tested,
#   working, broken. Collapsing the first two into "not failed" is exactly what made the
#   card unable to warn, and it is the mistake a boolean column would have forced.
# Contract: ai_connection_status holds one of two values or NULL; the predicates answer
#   independently, and a fresh organisation is "never tested" rather than "failed".

require 'rails_helper'

RSpec.describe 'Organisation AI connection state' do
  let(:organisation) { create(:organisation) }

  it 'starts out never tested, which is not the same as failed' do
    expect(organisation.ai_connection_never_tested?).to be(true)
    expect(organisation.ai_connection_failed?).to be(false)
    expect(organisation.ai_connection_ok?).to be(false)
  end

  it 'reports a successful check' do
    organisation.update!(ai_connection_status: Organisation::AI_CONNECTION_OK,
                         ai_connection_checked_at: Time.current)

    expect(organisation).to have_attributes(ai_connection_ok?: true, ai_connection_failed?: false,
                                            ai_connection_never_tested?: false)
  end

  it 'reports a failed check' do
    organisation.update!(ai_connection_status: Organisation::AI_CONNECTION_FAILED,
                         ai_connection_checked_at: Time.current)

    expect(organisation).to have_attributes(ai_connection_failed?: true, ai_connection_ok?: false,
                                            ai_connection_never_tested?: false)
  end

  # The timestamp answers "has anybody tried", the status answers "what came back". A
  # single column cannot hold both, and the card renders a different sentence for each:
  # an access tested a month ago that worked is not the same claim as one tested just now.
  it 'keeps the two columns answering different questions' do
    organisation.update!(ai_connection_checked_at: Time.current)

    expect(organisation.ai_connection_never_tested?).to be(false)
    expect(organisation.ai_connection_ok?).to be(false)
    expect(organisation.ai_connection_failed?).to be(false)
  end
end
